//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit

extension ChatListViewController {
    public var isViewVisible: Bool {
        get { viewState.isViewVisible }
        set {
            viewState.isViewVisible = newValue

            updateShouldBeUpdatingView()
            updateCellVisibility()
        }
    }

    fileprivate var shouldBeUpdatingView: Bool {
        get { viewState.shouldBeUpdatingView }
        set {
            guard viewState.shouldBeUpdatingView != newValue else {
                // Ignore redundant changes.
                return
            }
            viewState.shouldBeUpdatingView = newValue

            if newValue {
                loadCoordinator.loadIfNecessary(suppressAnimations: true)
            }
        }
    }

    // MARK: -

    public func loadIfNecessary() {
        loadCoordinator.loadIfNecessary()
    }

    func updateShouldBeUpdatingView() {
        AssertIsOnMainThread()

        let isAppForegroundAndActive = CurrentAppContext().isAppForegroundAndActive()

        self.shouldBeUpdatingView = self.isViewVisible && isAppForegroundAndActive
    }

    // MARK: -

    fileprivate func loadRenderStateForReset(viewInfo: CLVViewInfo,
                                             transaction: SDSAnyReadTransaction) -> CLVLoadResult {
        AssertIsOnMainThread()

        return CLVLoader.loadRenderStateForReset(viewInfo: viewInfo, transaction: transaction)
    }

    fileprivate func copyRenderStateAndDiff(viewInfo: CLVViewInfo) -> CLVLoadResult {
        AssertIsOnMainThread()
        return CLVLoader.newRenderStateWithViewInfo(viewInfo, lastRenderState: renderState)
    }

    fileprivate func loadNewRenderStateWithDiff(viewInfo: CLVViewInfo,
                                                updatedThreadIds: Set<String>,
                                                transaction: SDSAnyReadTransaction) -> CLVLoadResult {
        AssertIsOnMainThread()

        return CLVLoader.loadRenderStateAndDiff(viewInfo: viewInfo,
                                               updatedItemIds: updatedThreadIds,
                                               lastRenderState: renderState,
                                               transaction: transaction)
    }

    fileprivate func applyLoadResult(_ loadResult: CLVLoadResult, animated: Bool) {
        AssertIsOnMainThread()

        switch loadResult {
        case .renderStateForReset(renderState: let renderState):
            let previousSelection = tableDataSource.selectedThreads(in: tableView)
            tableDataSource.renderState = renderState

            threadViewModelCache.clear()
            cellContentCache.clear()
            conversationCellHeightCache = nil

            reloadTableData(withSelection: previousSelection)
        case .renderStateWithRowChanges(renderState: let renderState, let rowChanges):
            applyRowChanges(rowChanges, renderState: renderState, animated: animated)
        case .renderStateWithoutRowChanges(let renderState):
            tableDataSource.renderState = renderState
        case .reloadTable:
            reloadTableData()
        case .noChanges:
            break
        }

        tableDataSource.calcRefreshTimer()
        // We need to perform this regardless of the load result type.
        updateViewState()
        viewState.settingsButtonCreator.updateState(
            hasInboxChats: renderState.inboxCount > 0,
            hasArchivedChats: renderState.archiveCount > 0
        )
    }

    fileprivate func applyRowChanges(_ rowChanges: [CLVRowChange], renderState: CLVRenderState, animated: Bool) {
        AssertIsOnMainThread()

        let sectionDifference = renderState.sections.difference(from: tableDataSource.renderState.sections, by: { $0.type == $1.type })
        let isChangingFilter = tableDataSource.renderState.viewInfo.inboxFilter != renderState.viewInfo.inboxFilter
        tableDataSource.renderState = renderState

        let tableView = self.tableView
        let threadViewModelCache = self.threadViewModelCache
        let cellContentCache = self.cellContentCache

        let filterChangeAnimation = animated ? UITableView.RowAnimation.fade : .none
        let defaultRowAnimation = animated ? UITableView.RowAnimation.automatic : .none

        // only perform a beginUpdates/endUpdates block if really necessary, otherwise
        // strange scroll animations may occur
        var tableUpdatesPerformed = false
        let checkAndSetTableUpdates = { [weak self] in
            if !tableUpdatesPerformed, let self = self {
                tableView.beginUpdates()
                // animate all UI changes within the same transaction
                if tableView.isEditing && !self.viewState.multiSelectState.isActive {
                    tableView.setEditing(false, animated: true)
                }
                tableUpdatesPerformed = true
            }
        }

        // Ss soon as structural changes are applied to the table we can not use our optimized update implementation
        // anymore. All indexPaths are based on the old model (before any change was applied) and if we
        // animate move, insert and delete changes the indexPaths of the to be updated rows will differ.
        var useFallBackUpdateMechanism = false
        var removedSections = IndexSet()
        var insertedSections = IndexSet()

        for change in sectionDifference {
            switch change {
            case let .insert(offset, element: _, associatedWith: _):
                insertedSections.insert(offset)
            case let .remove(offset, element: _, associatedWith: _):
                removedSections.insert(offset)
            }
        }

        if !removedSections.isEmpty {
            checkAndSetTableUpdates()
            tableView.deleteSections(removedSections, with: .middle)
            useFallBackUpdateMechanism = true
        }

        for rowChange in rowChanges {
            threadViewModelCache.removeObject(forKey: rowChange.threadUniqueId)
            cellContentCache.removeObject(forKey: rowChange.threadUniqueId)

            switch rowChange.type {
            case .delete(let oldIndexPath):
                checkAndSetTableUpdates()
                tableView.deleteRows(at: [oldIndexPath], with: isChangingFilter ? filterChangeAnimation : defaultRowAnimation)
                useFallBackUpdateMechanism = true
            case .insert(let newIndexPath):
                checkAndSetTableUpdates()
                tableView.insertRows(at: [newIndexPath], with: isChangingFilter ? filterChangeAnimation : defaultRowAnimation)
                useFallBackUpdateMechanism = true
            case .move(let oldIndexPath, let newIndexPath):
                // NOTE: if we're moving within the same section, we perform
                //       moves using a "delete" and "insert" rather than a "move".
                //       This ensures that moved items are also reloaded. This is
                //       how UICollectionView performs reloads internally. We can't
                //       do this when changing sections, because it results in a weird
                //       animation. This should generally be safe, because you'll only
                //       move between sections when pinning / unpinning which doesn't
                //       require the moved item to be reloaded.
                checkAndSetTableUpdates()
                if oldIndexPath.section != newIndexPath.section {
                    tableView.moveRow(at: oldIndexPath, to: newIndexPath)
                } else {
                    tableView.deleteRows(at: [oldIndexPath], with: defaultRowAnimation)
                    tableView.insertRows(at: [newIndexPath], with: defaultRowAnimation)
                }
                useFallBackUpdateMechanism = true
            case .update(let oldIndexPath):
                if tableView.isEditing && !viewState.multiSelectState.isActive {
                    checkAndSetTableUpdates()
                }
                if !useFallBackUpdateMechanism, let tds = tableView.dataSource as? CLVTableDataSource {
                    useFallBackUpdateMechanism = !tds.updateVisibleCellContent(at: oldIndexPath, for: tableView)
                }
                if useFallBackUpdateMechanism {
                    checkAndSetTableUpdates()
                    tableView.reloadRows(at: [oldIndexPath], with: .none)
                }
            }
        }

        if !insertedSections.isEmpty {
            checkAndSetTableUpdates()
            tableView.insertSections(insertedSections, with: .top)
        }

        if tableUpdatesPerformed {
            tableView.endUpdates()
        }
    }
}

// MARK: -

private enum CLVLoadType {
    case resetAll
    case incrementalDiff(updatedThreadIds: Set<String>)
    case incrementalWithoutThreadUpdates
    case none
}

// MARK: -

public class CLVLoadCoordinator: Dependencies {
    public weak var viewController: ChatListViewController?
    private var loadInfoBuilder = CLVLoadInfoBuilder()

    private struct CLVLoadInfo {
        let viewInfo: CLVViewInfo
        let loadType: CLVLoadType
    }

    private class CLVLoadInfoBuilder {
        var shouldResetAll = false
        var updatedThreadIds = Set<String>()

        func build(
            chatListMode: ChatListMode,
            inboxFilter: InboxFilter?,
            isMultiselectActive: Bool,
            lastSelectedThreadId: String?,
            hasVisibleReminders: Bool,
            lastViewInfo: CLVViewInfo,
            transaction: SDSAnyReadTransaction
        ) -> CLVLoadInfo {
            let viewInfo = CLVViewInfo.build(
                chatListMode: chatListMode,
                inboxFilter: inboxFilter,
                isMultiselectActive: isMultiselectActive,
                lastSelectedThreadId: lastSelectedThreadId,
                hasVisibleReminders: hasVisibleReminders,
                transaction: transaction
            )

            if shouldResetAll {
                return CLVLoadInfo(viewInfo: viewInfo, loadType: .resetAll)
            } else if !updatedThreadIds.isEmpty || viewInfo.inboxFilter != lastViewInfo.inboxFilter {
                return CLVLoadInfo(viewInfo: viewInfo, loadType: .incrementalDiff(updatedThreadIds: updatedThreadIds))
            } else if viewInfo != lastViewInfo {
                return CLVLoadInfo(viewInfo: viewInfo, loadType: .incrementalWithoutThreadUpdates)
            } else {
                return CLVLoadInfo(viewInfo: viewInfo, loadType: .none)
            }
        }
    }

    public init() {
        loadInfoBuilder.shouldResetAll = true
    }

    public func scheduleHardReset() {
        AssertIsOnMainThread()

        loadInfoBuilder.shouldResetAll = true

        loadIfNecessary()
    }

    public func scheduleLoad(updatedThreadIds: some Collection<String>) {
        AssertIsOnMainThread()
        owsAssertDebug(!updatedThreadIds.isEmpty)

        loadInfoBuilder.updatedThreadIds.formUnion(updatedThreadIds)

        loadIfNecessary()
    }

    public func ensureFirstLoad() {
        AssertIsOnMainThread()

        guard let viewController else {
            owsFailDebug("Missing viewController.")
            return
        }

        // During main app launch, the chat list becomes visible _before_
        // app is foreground and active.  Therefore we need to make an
        // exception and update the view contents; otherwise, the home
        // view will briefly appear empty after launch.
        let shouldForceLoad = (!viewController.hasEverAppeared &&
                                viewController.tableDataSource.renderState.visibleThreadCount == 0)

        loadIfNecessary(suppressAnimations: true, shouldForceLoad: shouldForceLoad)
    }

    @objc
    public func applicationWillEnterForeground() {
        AssertIsOnMainThread()

        guard let viewController = viewController else {
            owsFailDebug("Missing viewController.")
            return
        }

        if viewController.isViewVisible {
            // When app returns from background, it should perform one load
            // immediately (before entering the foreground) without animations.
            // Otherwise, the user sees the changes that occurred in the
            // background animate in.
            loadIfNecessary(suppressAnimations: true, shouldForceLoad: true)
        } else {
            viewController.updateViewState()
        }
    }

    public func loadIfNecessary(suppressAnimations: Bool = false, shouldForceLoad: Bool = false) {
        AssertIsOnMainThread()

        guard let viewController else {
            owsFailDebug("Missing viewController.")
            return
        }

        guard viewController.shouldBeUpdatingView || shouldForceLoad else { return }

        // Copy the "current" load info, reset "next" load info.

        let reminderViews = viewController.viewState.reminderViews
        let hasVisibleReminders = reminderViews.hasVisibleReminders

        let loadResult: CLVLoadResult = databaseStorage.read { transaction in
            // Decide what kind of load we prefer.
            let loadInfo = loadInfoBuilder.build(
                chatListMode: viewController.viewState.chatListMode,
                inboxFilter: viewController.viewState.inboxFilter,
                isMultiselectActive: viewController.viewState.multiSelectState.isActive,
                lastSelectedThreadId: viewController.viewState.lastSelectedThreadId,
                hasVisibleReminders: hasVisibleReminders,
                lastViewInfo: viewController.renderState.viewInfo,
                transaction: transaction
            )

            // Reset the builder.
            loadInfoBuilder = CLVLoadInfoBuilder()

            // Perform the load.
            //
            // NOTE: we might not receive the kind of load that we requested.
            switch loadInfo.loadType {
            case .resetAll:
                return viewController.loadRenderStateForReset(
                    viewInfo: loadInfo.viewInfo,
                    transaction: transaction
                )

            case .incrementalDiff(let updatedThreadIds):
                return viewController.loadNewRenderStateWithDiff(
                    viewInfo: loadInfo.viewInfo,
                    updatedThreadIds: updatedThreadIds,
                    transaction: transaction
                )

            case .incrementalWithoutThreadUpdates:
                return viewController.copyRenderStateAndDiff(viewInfo: loadInfo.viewInfo)

            case .none:
                return .noChanges
            }
        }

        // Apply the load to the view.
        let shouldAnimate = !suppressAnimations && viewController.hasEverAppeared
        if shouldAnimate {
            viewController.applyLoadResult(loadResult, animated: shouldAnimate)
        } else {
            // Suppress animations.
            UIView.animate(withDuration: 0) {
                viewController.applyLoadResult(loadResult, animated: shouldAnimate)
            }
        }
    }
}
