import Observation
@MainActor
@Observable
public final class RemoteWorkspace {
  public static let maximumConcurrentRequestCount = 2
  public static let maximumQueuedRequestCount = 64
  public nonisolated static let maximumExpandedDirectoryCount = 30
  public static let maximumDirectoryStateCount = 32
  public static let maximumHistoryLocationCount =
    RemoteWorkspaceHistoryPolicy.maximumLocationCount
  public static let maximumHistoryByteCount =
    RemoteWorkspaceHistoryPolicy.maximumByteCount
  public static let maximumScrollRestorationTokenByteCount =
    RemoteWorkspaceHistoryPolicy.maximumScrollRestorationTokenByteCount
  public let id: RemoteWorkspaceID
  /// Trusted composition-assigned provider classification. Immutable for the
  /// workspace's lifetime; provider responses cannot change it.
  public let providerMode: RemoteProviderMode
  public private(set) var availability: RemoteWorkspaceAvailability = .idle
  public private(set) var currentDirectory: RemotePath?
  public private(set) var currentListing: RemoteDirectoryListing?
  public private(set) var pendingDirectory: RemotePath?
  public private(set) var directoryStates: [RemotePath: RemoteDirectoryLoadState] = [:]
  public private(set) var backHistory: [RemoteWorkspaceLocation] = []
  public private(set) var forwardHistory: [RemoteWorkspaceLocation] = []
  public private(set) var selectedEntry: RemotePath?
  public private(set) var scrollRestorationToken: RemoteScrollRestorationToken?
  public private(set) var expandedDirectories: Set<RemotePath> = []
  public var cachedListingCount: Int { directoryCache.listingCount }
  public var activeRequestCount: Int { activeRequests.count }
  public var queuedRequestCount: Int { queuedRequests.count }
  var trackedRequestPathCount: Int { latestGenerationByPath.count }
  public var canGoBack: Bool { availability == .available && !backHistory.isEmpty }
  public var canGoForward: Bool { availability == .available && !forwardHistory.isEmpty }
  public var canGoToParent: Bool {
    availability == .available && currentDirectory?.parent != nil
  }
  @ObservationIgnored private let provider: any RemoteFileProvider
  @ObservationIgnored private var initialLoadTask: Task<Void, Never>?
  @ObservationIgnored private var closeTask: Task<Void, Never>?
  @ObservationIgnored private var requestGeneration: UInt64 = 0
  @ObservationIgnored private var directoryCache: RemoteDirectoryCache
  @ObservationIgnored private var latestGenerationByPath: [RemotePath: UInt64] = [:]
  @ObservationIgnored private var pendingNavigationGeneration: UInt64?
  @ObservationIgnored private var pendingRefreshGeneration: UInt64?
  @ObservationIgnored private var queuedRequests: [RemotePath: RemoteWorkspaceDirectoryRequest] =
    [:]
  @ObservationIgnored private var queueOrder: [RemotePath] = []
  @ObservationIgnored private var activeRequests: [RemotePath: RemoteWorkspaceActiveRequest] = [:]
  @ObservationIgnored private var directoryStateOrder: [RemotePath] = []
  public init(
    id: RemoteWorkspaceID = RemoteWorkspaceID(),
    composition: RemoteProviderComposition,
    directoryCache: RemoteDirectoryCache = RemoteDirectoryCache()
  ) {
    self.id = id
    self.provider = composition.provider
    self.providerMode = composition.mode
    self.directoryCache = directoryCache
  }

  public func start() {
    guard availability == .idle || isFailed else { return }
    beginInitialLoad()
  }
  public func retry() {
    guard isFailed else { return }
    beginInitialLoad()
  }
  /// The shared bounded projection of every visible loaded row. The sidebar
  /// renders exactly these rows, and selection validation accepts exactly the
  /// projected entry paths, so the two can never diverge.
  public var visibleProjection: RemoteWorkspaceVisibleEntryProjection {
    RemoteWorkspaceVisibleEntryProjection(
      currentListing: currentListing,
      expandedDirectories: expandedDirectories,
      directoryStates: directoryStates
    )
  }
  public func selectEntry(_ path: RemotePath?) {
    guard availability == .available else { return }
    guard let path else {
      selectedEntry = nil
      return
    }
    guard visibleProjection.isSelectable(path) else { return }
    selectedEntry = path
  }
  public func setScrollRestorationToken(
    _ token: RemoteScrollRestorationToken?
  ) {
    guard availability == .available else { return }
    scrollRestorationToken =
      RemoteWorkspaceHistoryPolicy
      .acceptedScrollRestorationToken(token)
  }
  public func openDirectory(_ path: RemotePath) {
    guard canAcceptDirectoryActions, isKnownDirectory(path) else { return }
    navigateOrdinarily(to: path)
  }
  public func goBack() {
    guard canGoBack,
      let source = currentLocation,
      let destination = backHistory.last
    else { return }
    let plan = boundedNavigationPlan(
      destination: destination,
      backHistory: Array(backHistory.dropLast()),
      forwardHistory: forwardHistory + [source]
    )
    scheduleNavigation(plan)
  }
  public func goForward() {
    guard canGoForward,
      let source = currentLocation,
      let destination = forwardHistory.last
    else { return }
    let plan = boundedNavigationPlan(
      destination: destination,
      backHistory: backHistory + [source],
      forwardHistory: Array(forwardHistory.dropLast())
    )
    scheduleNavigation(plan)
  }
  public func goToParent() {
    guard canGoToParent, let parent = currentDirectory?.parent else { return }
    navigateOrdinarily(to: parent)
  }
  public func openBreadcrumb(_ path: RemotePath) {
    guard canAcceptDirectoryActions,
      path != currentDirectory,
      currentDirectory?.breadcrumbPaths.contains(path) == true
    else { return }
    navigateOrdinarily(to: path)
  }
  public func refresh() {
    guard canAcceptDirectoryActions,
      let currentDirectory,
      let currentListing
    else { return }
    cancelPendingNavigation()
    cancelPendingRefresh(markCancelled: false)
    directoryCache = directoryCache.pinning(currentDirectory)
    let request = RemoteWorkspaceDirectoryRequest(
      path: currentDirectory,
      generation: nextGeneration(),
      purpose: .refresh(selectedEntry: selectedEntry),
      previousListing: currentListing
    )
    pendingRefreshGeneration = request.generation
    pendingDirectory = currentDirectory
    enqueue(request, priority: true)
  }
  public func setExpanded(_ path: RemotePath, isExpanded: Bool) {
    guard canAcceptDirectoryActions else { return }
    if !isExpanded {
      collapse(path)
      return
    }
    guard isKnownDirectory(path) else { return }
    let wasExpanded = expandedDirectories.contains(path)
    guard
      wasExpanded
        || expandedDirectories.count < Self.maximumExpandedDirectoryCount
    else {
      replaceDirectoryState(
        .failed(
          error: RemoteFileError(category: .limitExceeded),
          previousListing: directoryStates[path]?.visibleListing
        ),
        for: path
      )
      return
    }
    expandedDirectories = expandedDirectories.union([path])
    if let cached = cachedListing(for: path) {
      replaceDirectoryState(RemoteWorkspaceDirectoryStatePolicy.listingState(cached), for: path)
      return
    }
    if wasExpanded
      && (activeRequests[path] != nil || queuedRequests[path] != nil)
    {
      return
    }
    scheduleExpansion(path)
  }
  public func retryDirectory(_ path: RemotePath) {
    guard canAcceptDirectoryActions,
      expandedDirectories.contains(path),
      RemoteWorkspaceDirectoryStatePolicy.isFailedOrCancelled(directoryStates[path])
    else { return }
    scheduleExpansion(path)
  }
  public func cancelCurrentRequest() {
    if availability == .connecting || availability == .loadingInitialDirectory {
      cancelInitialRequest()
      return
    }
    guard availability == .available else { return }
    if pendingNavigationGeneration != nil {
      cancelPendingNavigation()
    } else if pendingRefreshGeneration != nil {
      cancelPendingRefresh(markCancelled: true)
    }
  }
  public func close() async {
    if availability == .closed { return }
    if availability != .closing {
      availability = .closing
      _ = nextGeneration()
      let initialTasks = [initialLoadTask].compactMap { $0 }
      let directoryTasks = activeRequests.values.map(\.task)
      let activeTasks = initialTasks + directoryTasks
      activeTasks.forEach { $0.cancel() }
      initialLoadTask = nil
      queuedRequests = [:]
      queueOrder = []
      pendingDirectory = nil
      pendingNavigationGeneration = nil
      pendingRefreshGeneration = nil
      let provider = provider
      closeTask = Task {
        await RemoteWorkspaceProviderOperations.settleClose(
          provider: provider,
          activeTasks: activeTasks
        )
      }
    }
    guard let closeTask else {
      finishCloseIfNeeded()
      return
    }
    await closeTask.value
    finishCloseIfNeeded()
  }
  private var isFailed: Bool {
    if case .failed = availability { return true }
    return false
  }
  private var canAcceptDirectoryActions: Bool {
    availability == .available && closeTask == nil
  }
  private var currentLocation: RemoteWorkspaceLocation? {
    currentDirectory.map {
      RemoteWorkspaceLocation(
        directory: $0,
        selectedEntry: selectedEntry,
        scrollRestorationToken: scrollRestorationToken
      )
    }
  }
  private func beginInitialLoad() {
    let generation = nextGeneration()
    let workspaceID = id
    let provider = provider
    let predecessor = initialLoadTask
    pendingDirectory = nil
    availability = .connecting
    initialLoadTask = Task { @MainActor [weak self] in
      if let predecessor {
        await predecessor.value
      }
      guard let self,
        self.acceptsInitial(
          workspaceID: workspaceID,
          generation: generation
        )
      else { return }
      do {
        let directory = try await RemoteWorkspaceProviderOperations.resolveInitialDirectory(
          using: provider)
        guard
          self.acceptsInitial(
            workspaceID: workspaceID,
            generation: generation
          )
        else { return }
        self.beginInitialListing(directory, generation: generation)
        let listing = try await RemoteWorkspaceProviderOperations.listDirectory(
          directory, using: provider)
        self.completeInitialListing(
          listing,
          requestedDirectory: directory,
          workspaceID: workspaceID,
          generation: generation
        )
      } catch {
        self.completeInitialFailure(
          RemoteWorkspaceProviderOperations.remoteFileError(from: error),
          workspaceID: workspaceID,
          generation: generation
        )
      }
    }
  }
  private func beginInitialListing(_ directory: RemotePath, generation: UInt64) {
    guard generation == requestGeneration else { return }
    pendingDirectory = directory
    availability = .loadingInitialDirectory
    replaceDirectoryState(
      .loading(previousListing: directoryStates[directory]?.visibleListing),
      for: directory
    )
  }
  private func completeInitialListing(
    _ listing: RemoteDirectoryListing,
    requestedDirectory: RemotePath,
    workspaceID: RemoteWorkspaceID,
    generation: UInt64
  ) {
    guard acceptsInitial(workspaceID: workspaceID, generation: generation) else {
      return
    }
    guard listing.directory == requestedDirectory else {
      completeInitialFailure(
        RemoteWorkspaceProviderOperations.malformedDirectoryError(),
        workspaceID: workspaceID,
        generation: generation
      )
      return
    }
    do {
      directoryCache =
        try directoryCache
        .pinning(requestedDirectory)
        .inserting(listing)
      reconcileDirectoryStatePayloads()
    } catch {
      completeInitialFailure(
        RemoteFileError(category: .limitExceeded),
        workspaceID: workspaceID,
        generation: generation
      )
      return
    }
    guard directoryCache.retainedDirectories.contains(requestedDirectory) else {
      completeInitialFailure(
        RemoteFileError(category: .limitExceeded),
        workspaceID: workspaceID,
        generation: generation
      )
      return
    }
    currentDirectory = requestedDirectory
    currentListing = listing
    pendingDirectory = nil
    replaceDirectoryState(
      RemoteWorkspaceDirectoryStatePolicy.listingState(listing), for: requestedDirectory)
    availability = .available
  }
  private func completeInitialFailure(
    _ error: RemoteFileError,
    workspaceID: RemoteWorkspaceID,
    generation: UInt64
  ) {
    guard acceptsInitial(workspaceID: workspaceID, generation: generation) else {
      return
    }
    if let pendingDirectory {
      let previous = directoryStates[pendingDirectory]?.visibleListing
      replaceDirectoryState(
        error.category == .cancelled
          ? .cancelled(previousListing: previous)
          : .failed(error: error, previousListing: previous),
        for: pendingDirectory
      )
    }
    pendingDirectory = nil
    availability = .failed(error)
  }
  private func acceptsInitial(
    workspaceID: RemoteWorkspaceID,
    generation: UInt64
  ) -> Bool {
    id == workspaceID
      && requestGeneration == generation
      && availability != .closing
      && availability != .closed
  }
  private func cancelInitialRequest() {
    _ = nextGeneration()
    initialLoadTask?.cancel()
    let cancellation = RemoteFileError(category: .cancelled)
    if let pendingDirectory {
      replaceDirectoryState(
        .cancelled(
          previousListing: directoryStates[pendingDirectory]?.visibleListing
        ),
        for: pendingDirectory
      )
    }
    pendingDirectory = nil
    availability = .failed(cancellation)
  }
  private func navigateOrdinarily(to path: RemotePath) {
    guard path != currentDirectory, let source = currentLocation else { return }
    let destination = RemoteWorkspaceLocation(
      directory: path,
      selectedEntry: nil,
      scrollRestorationToken: nil
    )
    scheduleNavigation(
      boundedNavigationPlan(
        destination: destination,
        backHistory: backHistory + [source],
        forwardHistory: []
      )
    )
  }
  private func boundedNavigationPlan(
    destination: RemoteWorkspaceLocation,
    backHistory: [RemoteWorkspaceLocation],
    forwardHistory: [RemoteWorkspaceLocation]
  ) -> RemoteWorkspaceNavigationPlan {
    let histories = RemoteWorkspaceHistoryPolicy.bounded(
      back: backHistory,
      forward: forwardHistory
    )
    return RemoteWorkspaceNavigationPlan(
      destination: destination,
      backHistory: histories.back,
      forwardHistory: histories.forward
    )
  }
  private func scheduleNavigation(_ plan: RemoteWorkspaceNavigationPlan) {
    cancelPendingNavigation()
    cancelPendingRefresh(markCancelled: false)
    let path = plan.destination.directory
    let request = RemoteWorkspaceDirectoryRequest(
      path: path,
      generation: nextGeneration(),
      purpose: .navigation(plan),
      previousListing: directoryStates[path]?.visibleListing
    )
    pendingNavigationGeneration = request.generation
    pendingDirectory = path
    if let cached = cachedListing(for: path) {
      applySuccessfulListing(cached, for: request)
      return
    }
    enqueue(request, priority: true)
  }
  private func scheduleExpansion(_ path: RemotePath) {
    let request = RemoteWorkspaceDirectoryRequest(
      path: path,
      generation: nextGeneration(),
      purpose: .expansion,
      previousListing: directoryStates[path]?.visibleListing
    )
    enqueue(request, priority: false)
  }
  private func enqueue(_ request: RemoteWorkspaceDirectoryRequest, priority: Bool) {
    supersedeRequest(at: request.path)
    guard
      queuedRequests[request.path] != nil
        || activeRequests[request.path] != nil
        || queuedRequests.count < Self.maximumQueuedRequestCount
    else {
      failToQueue(request)
      return
    }
    latestGenerationByPath = latestGenerationByPath.merging(
      [request.path: request.generation]
    ) { _, replacement in replacement }
    queuedRequests = queuedRequests.merging([request.path: request]) {
      _, replacement in replacement
    }
    queueOrder = queueOrder.filter { $0 != request.path }
    queueOrder =
      priority
      ? [request.path] + queueOrder
      : queueOrder + [request.path]
    replaceDirectoryState(
      .loading(previousListing: request.previousListing),
      for: request.path
    )
    pumpRequests()
  }
  private func supersedeRequest(at path: RemotePath) {
    if let active = activeRequests[path] {
      active.task.cancel()
    }
    queuedRequests = queuedRequests.filter { $0.key != path }
    queueOrder = queueOrder.filter { $0 != path }
  }
  private func pumpRequests() {
    guard canAcceptDirectoryActions else { return }
    while activeRequests.count < Self.maximumConcurrentRequestCount,
      let path = queueOrder.first(where: { activeRequests[$0] == nil }),
      let request = queuedRequests[path]
    {
      queueOrder = queueOrder.filter { $0 != path }
      queuedRequests = queuedRequests.filter { $0.key != path }
      let provider = provider
      let workspaceID = id
      let task = Task { @MainActor [weak self] in
        do {
          let listing = try await RemoteWorkspaceProviderOperations.listDirectory(
            path, using: provider)
          self?.completeDirectoryRequest(
            request,
            result: .success(listing),
            workspaceID: workspaceID
          )
        } catch {
          self?.completeDirectoryRequest(
            request,
            result: .failure(RemoteWorkspaceProviderOperations.remoteFileError(from: error)),
            workspaceID: workspaceID
          )
        }
      }
      activeRequests = activeRequests.merging([
        path: RemoteWorkspaceActiveRequest(request: request, task: task)
      ]) { _, replacement in replacement }
    }
  }
  private func completeDirectoryRequest(
    _ request: RemoteWorkspaceDirectoryRequest,
    result: Result<RemoteDirectoryListing, RemoteFileError>,
    workspaceID: RemoteWorkspaceID
  ) {
    guard id == workspaceID,
      activeRequests[request.path]?.request.generation == request.generation
    else {
      return
    }
    activeRequests = activeRequests.filter { $0.key != request.path }
    if isCurrent(request), availability == .available {
      switch result {
      case .success(let listing) where listing.directory == request.path:
        applySuccessfulListing(listing, for: request)
      case .success:
        applyFailedRequest(
          RemoteWorkspaceProviderOperations.malformedDirectoryError(), for: request)
      case .failure(let error):
        applyFailedRequest(error, for: request)
      }
    }
    pruneSettledRequestGenerations()
    pumpRequests()
  }
  private func isCurrent(_ request: RemoteWorkspaceDirectoryRequest) -> Bool {
    guard latestGenerationByPath[request.path] == request.generation else {
      return false
    }
    switch request.purpose {
    case .navigation:
      return pendingNavigationGeneration == request.generation
    case .refresh:
      return pendingRefreshGeneration == request.generation
    case .expansion:
      return expandedDirectories.contains(request.path)
    }
  }
  private func applySuccessfulListing(
    _ listing: RemoteDirectoryListing,
    for request: RemoteWorkspaceDirectoryRequest
  ) {
    do {
      switch request.purpose {
      case .navigation, .refresh:
        directoryCache =
          try directoryCache
          .pinning(request.path)
          .inserting(listing)
      case .expansion:
        directoryCache = try directoryCache.inserting(listing)
      }
      reconcileDirectoryStatePayloads()
    } catch {
      applyFailedRequest(RemoteFileError(category: .limitExceeded), for: request)
      return
    }
    guard directoryCache.retainedDirectories.contains(request.path) else {
      applyFailedRequest(
        RemoteFileError(category: .limitExceeded),
        for: request
      )
      return
    }
    replaceDirectoryState(
      RemoteWorkspaceDirectoryStatePolicy.listingState(listing), for: request.path)
    switch request.purpose {
    case .navigation(let plan):
      currentDirectory = request.path
      currentListing = listing
      backHistory = plan.backHistory
      forwardHistory = plan.forwardHistory
      selectedEntry = restoredSelection(
        plan.destination.selectedEntry,
        exactOnly: true
      )
      scrollRestorationToken = plan.destination.scrollRestorationToken
      pendingNavigationGeneration = nil
      pendingDirectory = nil
    case .refresh(let priorSelection):
      currentListing = listing
      selectedEntry = restoredSelection(priorSelection, exactOnly: false)
      pendingRefreshGeneration = nil
      pendingDirectory = nil
    case .expansion:
      // Cache insertion or eviction may have hidden the selected descendant.
      repairSelectionIfHidden()
    }
  }
  private func applyFailedRequest(
    _ error: RemoteFileError,
    for request: RemoteWorkspaceDirectoryRequest
  ) {
    let state: RemoteDirectoryLoadState =
      error.category == .cancelled
      ? .cancelled(previousListing: request.previousListing)
      : .failed(error: error, previousListing: request.previousListing)
    replaceDirectoryState(state, for: request.path)
    switch request.purpose {
    case .navigation:
      pendingNavigationGeneration = nil
      pendingDirectory = nil
    case .refresh:
      pendingRefreshGeneration = nil
      pendingDirectory = nil
    case .expansion:
      break
    }
  }
  private func failToQueue(_ request: RemoteWorkspaceDirectoryRequest) {
    applyFailedRequest(
      RemoteFileError(category: .limitExceeded),
      for: request
    )
  }
  private func cancelPendingNavigation() {
    guard let generation = pendingNavigationGeneration else { return }
    cancelRequest(generation: generation, markCancelled: true)
    pendingNavigationGeneration = nil
    pendingDirectory = nil
    pruneSettledRequestGenerations()
  }
  private func cancelPendingRefresh(markCancelled: Bool) {
    guard let generation = pendingRefreshGeneration else { return }
    cancelRequest(generation: generation, markCancelled: markCancelled)
    pendingRefreshGeneration = nil
    pendingDirectory = nil
    pruneSettledRequestGenerations()
  }
  private func cancelRequest(generation: UInt64, markCancelled: Bool) {
    if let (path, request) = queuedRequests.first(where: {
      $0.value.generation == generation
    }) {
      queuedRequests = queuedRequests.filter { $0.key != path }
      queueOrder = queueOrder.filter { $0 != path }
      if markCancelled {
        replaceDirectoryState(
          .cancelled(previousListing: request.previousListing),
          for: path
        )
      } else if let previousListing = request.previousListing {
        replaceDirectoryState(
          RemoteWorkspaceDirectoryStatePolicy.listingState(previousListing), for: path)
      }
      return
    }
    guard
      let (path, active) = activeRequests.first(where: {
        $0.value.request.generation == generation
      })
    else { return }
    active.task.cancel()
    if markCancelled {
      replaceDirectoryState(
        .cancelled(previousListing: active.request.previousListing),
        for: path
      )
    } else if let previous = active.request.previousListing {
      replaceDirectoryState(RemoteWorkspaceDirectoryStatePolicy.listingState(previous), for: path)
    }
  }
  private func collapse(_ path: RemotePath) {
    expandedDirectories = expandedDirectories.subtracting([path])
    // Collapsing the ancestor of the selected descendant keeps a visible,
    // valid selection: the collapsed directory itself.
    if let selected = selectedEntry, path.isAncestor(of: selected) {
      selectedEntry = path
    }
    if let queued = queuedRequests[path] {
      queuedRequests = queuedRequests.filter { $0.key != path }
      queueOrder = queueOrder.filter { $0 != path }
      replaceDirectoryState(
        .cancelled(previousListing: queued.previousListing),
        for: path
      )
    }
    if let active = activeRequests[path], case .expansion = active.request.purpose {
      active.task.cancel()
      replaceDirectoryState(
        .cancelled(previousListing: active.request.previousListing),
        for: path
      )
    }
    pruneSettledRequestGenerations()
    pruneDirectoryStates()
  }
  private func cachedListing(for path: RemotePath) -> RemoteDirectoryListing? {
    let access = directoryCache.accessing(path)
    directoryCache = access.cache
    return access.listing
  }
  private func isKnownDirectory(_ path: RemotePath) -> Bool {
    if path == currentDirectory { return true }
    return visibleProjection.entry(for: path)?.kind == .directory
  }
  /// Documented selection-restoration policy: the exact raw path survives when
  /// it is still a visible loaded entry. Otherwise history restoration
  /// (`exactOnly`) clears the selection, while refresh repair moves it to the
  /// nearest still-visible ancestor directory below the current directory, or
  /// clears it. Display-name equality never participates.
  private func restoredSelection(
    _ selection: RemotePath?,
    exactOnly: Bool
  ) -> RemotePath? {
    guard let selection else { return nil }
    let projection = visibleProjection
    if projection.isSelectable(selection) { return selection }
    guard !exactOnly else { return nil }
    var ancestor = selection.parent
    while let candidate = ancestor {
      if candidate == currentDirectory { return nil }
      if projection.entry(for: candidate)?.kind == .directory {
        return candidate
      }
      ancestor = candidate.parent
    }
    return nil
  }
  private func repairSelectionIfHidden() {
    guard let selected = selectedEntry else { return }
    selectedEntry = restoredSelection(selected, exactOnly: false)
  }
  private func nextGeneration() -> UInt64 {
    precondition(requestGeneration < UInt64.max)
    requestGeneration += 1
    return requestGeneration
  }
  private func pruneSettledRequestGenerations() {
    let retainedGenerations = Set(
      activeRequests.values.map(\.request.generation)
        + queuedRequests.values.map(\.generation)
        + [pendingNavigationGeneration, pendingRefreshGeneration]
        .compactMap { $0 }
    )
    latestGenerationByPath = latestGenerationByPath.filter {
      retainedGenerations.contains($0.value)
    }
  }
  private func replaceDirectoryState(
    _ state: RemoteDirectoryLoadState,
    for directory: RemotePath
  ) {
    let boundedState =
      RemoteWorkspaceDirectoryStatePolicy
      .retainingOnlyCachedListing(
        state,
        for: directory,
        retainedDirectories: directoryCache.retainedDirectories
      )
    directoryStates = directoryStates.merging([directory: boundedState]) {
      _, replacement in replacement
    }
    directoryStateOrder =
      directoryStateOrder.filter { $0 != directory }
      + [directory]
    pruneDirectoryStates()
  }
  private func reconcileDirectoryStatePayloads() {
    directoryStates =
      RemoteWorkspaceDirectoryStatePolicy
      .reconcilingListingPayloads(
        in: directoryStates,
        retainedDirectories: directoryCache.retainedDirectories
      )
  }
  private func pruneDirectoryStates() {
    let protectedDirectories =
      expandedDirectories
      .union([currentDirectory, pendingDirectory].compactMap { $0 })
    while directoryStates.count > Self.maximumDirectoryStateCount,
      let candidate = directoryStateOrder.first(where: {
        !protectedDirectories.contains($0)
      })
    {
      directoryStates = directoryStates.filter { $0.key != candidate }
      directoryStateOrder = directoryStateOrder.filter { $0 != candidate }
    }
  }
  private func finishCloseIfNeeded() {
    guard availability == .closing else { return }
    currentDirectory = nil
    currentListing = nil
    pendingDirectory = nil
    directoryStates = [:]
    backHistory = []
    forwardHistory = []
    selectedEntry = nil
    scrollRestorationToken = nil
    expandedDirectories = []
    directoryCache = directoryCache.clearing()
    latestGenerationByPath = [:]
    queuedRequests = [:]
    queueOrder = []
    activeRequests = [:]
    directoryStateOrder = []
    closeTask = nil
    availability = .closed
  }
}
