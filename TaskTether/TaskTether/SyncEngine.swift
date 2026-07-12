//
//  SyncEngine.swift
//  TaskTether
//
//  Created: 13/03/2026 · 22:00
//  Updated: 13/03/2026 · 22:00
//

import Foundation
import Combine
import EventKit

// MARK: - SyncState

enum SyncState: Equatable {
    case idle
    case syncing
    case error(String)
}

// MARK: - SyncEngine

class SyncEngine: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state:      SyncState = .idle
    @Published private(set) var tasks:      [TetherTask] = []
    @Published private(set) var lastSyncAt: Date? = nil

    // MARK: - Dependencies

    private let remindersManager:   RemindersManager
    private let googleTasksManager: GoogleTasksManager
    private let authManager:        GoogleAuthManager
    private let themeManager:       ThemeManager
    let idStore:                    IDStore       = IDStore()
    let statsStore:                 StatsStore    = StatsStore()
    private let snapshotStore:      SnapshotStore = SnapshotStore()

    // MARK: - Internal State

    private var previousSnapshot:    [TetherTask] = []
    private var timer:               Timer?
    private var isSyncing            = false

    // True when the next sync must run in reconciliation mode — see init.
    // Cleared after the first successful sync writes a fresh baseline.
    private var needsReconciliation  = false

    // Gap after which the baseline is no longer trusted for deletions.
    // 24 hours: comfortably longer than any normal between-sync interval,
    // comfortably shorter than "I stopped using the app for weeks".
    private static let reconciliationGap: TimeInterval = 24 * 60 * 60

    // Deletion candidates from the previous sync cycle.
    // A task must be absent from Google for TWO consecutive cycles before
    // we delete it from Reminders — guards against transient fetch failures.
    private var remindersDeleteCandidates: Set<String> = []  // remindersIds
    private var googleDeleteCandidates:    Set<String> = []  // googleIds
    private var consecutiveGoogleZero:     Int          = 0  // consecutive cycles with 0 Google tasks

    // MARK: - Init

    init(
        remindersManager:   RemindersManager,
        googleTasksManager: GoogleTasksManager,
        authManager:        GoogleAuthManager,
        themeManager:       ThemeManager
    ) {
        self.remindersManager   = remindersManager
        self.googleTasksManager = googleTasksManager
        self.authManager        = authManager
        self.themeManager       = themeManager

        // Restore the baseline from the previous session so the first sync
        // after a relaunch performs a real three-way merge instead of
        // starting blind.
        let restored          = snapshotStore.load()
        self.previousSnapshot = restored ?? []
        self.lastSyncAt       = snapshotStore.lastSyncAt

        // Reconciliation is required when there is no baseline at all, or
        // the last sync is older than the gap threshold. In either case the
        // stored links may point at tasks that were deleted or re-created
        // while the app was off, so the first sync must not delete anything.
        let lastSync = snapshotStore.lastSyncAt
        self.needsReconciliation = restored == nil
            || lastSync == nil
            || Date().timeIntervalSince(lastSync!) > Self.reconciliationGap
    }

    // MARK: - Baseline Persistence

    // Called at every point previousSnapshot is reassigned so the on-disk
    // baseline can never drift from the in-memory one.
    private func persistBaseline() {
        snapshotStore.save(previousSnapshot)
        snapshotStore.lastSyncAt = lastSyncAt
    }

    // MARK: - Lifecycle

    func start() {
        scheduleTimer()
        scheduleMidnightRefresh()
        Task { await sync() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Timer

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = TimeInterval(themeManager.syncInterval * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.rescheduleIfIntervalChanged()
            Task { await self?.sync() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func rescheduleIfIntervalChanged() {
        let expected = TimeInterval(themeManager.syncInterval * 60)
        guard let current = timer,
              abs(current.timeInterval - expected) > 1 else { return }
        scheduleTimer()
    }

    func syncNow() {
        Task { await sync() }
    }

    // MARK: - Sync Cycle

    @MainActor
    private func sync() async {
        guard !isSyncing,
              authManager.isAuthenticated,
              remindersManager.isAuthorised,
              googleTasksManager.isConnected else {
            if state == .syncing { state = .idle }
            return
        }

        isSyncing = true
        state     = .syncing

        do {
            async let remindersFetch   = fetchReminders()
            async let googleTasksFetch = fetchGoogleTasks()
            let (reminderTasks, googleTasks) = try await (remindersFetch, googleTasksFetch)

            let diff: SyncDiff
            if needsReconciliation {
                #if DEBUG
                print("SyncEngine: reconciliation sync — links repaired, no deletions")
                #endif
                repairLinks(remindersTasks: reminderTasks, googleTasks: googleTasks)
                diff = buildReconciliationDiff(
                    remindersTasks: reminderTasks,
                    googleTasks:    googleTasks
                )
            } else {
                diff = buildDiff(
                    remindersTasks: reminderTasks,
                    googleTasks:    googleTasks,
                    previous:       previousSnapshot
                )
            }

            await applyDiff(diff)

            // Re-fetch both sides after applying diff so order and merge
            // reflect any tasks that were created during applyDiff.
            async let freshRemindersFetch   = fetchReminders()
            async let freshGoogleTasksFetch = fetchGoogleTasks()
            let (freshReminders, freshGoogleTasks) = try await (freshRemindersFetch, freshGoogleTasksFetch)

            let merged = await buildMergedList(
                remindersTasks: freshReminders,
                googleTasks:    freshGoogleTasks
            )

            // Update IDStore order from fresh Google fetch order.
            // Google Tasks returns items in position order when orderBy=position is set.
            let googleOrderedRids = freshGoogleTasks.compactMap { gTask -> String? in
                guard let gid = gTask.googleTasksId else { return nil }
                return idStore.remindersId(for: gid)
            }
            if !googleOrderedRids.isEmpty {
                // Reminders-only tasks (not yet linked) go at the end
                let remindersOnlyRids = merged.compactMap { $0.remindersId }
                    .filter { !googleOrderedRids.contains($0) }
                idStore.setOrder(googleOrderedRids + remindersOnlyRids)
            }

            // Update deletion candidate sets for next cycle.
            // A candidate is cleared only when the task RETURNS to the platform
            // it was deleted from — meaning the deletion was a transient failure.
            // We never clear candidates just because the task is still present
            // on the OTHER platform.
            let presentRids = Set(freshReminders.compactMap { $0.remindersId })
            let presentGids = Set(freshGoogleTasks.compactMap { $0.googleTasksId })

            // Reminders candidates (task absent from Google):
            // Clear only when the task RETURNS to Google (transient failure recovered).
            let remindersCandidatesThatReturnedToGoogle = remindersDeleteCandidates.filter { rid in
                guard let gid = idStore.googleId(for: rid) else { return false }
                return presentGids.contains(gid)
            }
            remindersDeleteCandidates = remindersDeleteCandidates
                .union(diff.addToRemindersDeleteCandidates)
                .subtracting(remindersCandidatesThatReturnedToGoogle)

            // Google candidates (task absent from Reminders):
            // Clear only when the task RETURNS to Reminders (transient failure recovered).
            let googleCandidatesThatReturnedToReminders = googleDeleteCandidates.filter { gid in
                guard let rid = idStore.remindersId(for: gid) else { return false }
                return presentRids.contains(rid)
            }
            googleDeleteCandidates = googleDeleteCandidates
                .union(diff.addToGoogleDeleteCandidates)
                .subtracting(googleCandidatesThatReturnedToReminders)

            tasks            = sortedByOrder(merged)
            previousSnapshot = tasks
            lastSyncAt       = Date()
            state            = .idle
            persistBaseline()
            // A fresh baseline now exists — normal diffing (including
            // deletion detection) is safe from the next cycle onwards.
            needsReconciliation = false

            // Record today's stats — done after sort so todayTasks is accurate.
            // Clear today's entry when there are no tasks so stale data from a
            // previous session doesn't show a false score.
            let todayAll = todayTasks
            statsStore.record(
                total:     todayAll.count,
                completed: todayAll.filter { $0.isCompleted }.count
            )
            if todayAll.isEmpty { statsStore.clearToday() }

        } catch {
            state = .error(error.localizedDescription)
        }

        isSyncing = false
    }

    // MARK: - Fetch

    private func fetchReminders() async throws -> [TetherTask] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let reminders = self.remindersManager.fetchTasks()
                let tasks = reminders.map { TetherTask(from: $0) }
                continuation.resume(returning: tasks)
            }
        }
    }

    private func fetchGoogleTasks() async throws -> [TetherTask] {
        try await withCheckedThrowingContinuation { continuation in
            self.googleTasksManager.fetchTasks { googleTasks in
                let tasks = googleTasks.map { TetherTask(from: $0) }
                continuation.resume(returning: tasks)
            }
        }
    }

    // MARK: - Diff

    private struct SyncDiff {
        var addToReminders:                [TetherTask] = []
        var addToGoogle:                   [TetherTask] = []
        var updateInGoogle:                [TetherTask] = []
        var updateInReminders:             [TetherTask] = []
        var deleteFromReminders:           [String]     = []
        var deleteFromGoogle:              [String]     = []
        var addToRemindersDeleteCandidates: Set<String>  = []
        var addToGoogleDeleteCandidates:    Set<String>  = []
    }

    @MainActor
    private func buildDiff(
        remindersTasks: [TetherTask],
        googleTasks:    [TetherTask],
        previous:       [TetherTask]
    ) -> SyncDiff {
        var diff = SyncDiff()

        let remindersByRid = Dictionary(uniqueKeysWithValues:
            remindersTasks.compactMap { t in t.remindersId.map { ($0, t) } })
        let googleByGid    = Dictionary(uniqueKeysWithValues:
            googleTasks.compactMap { t in t.googleTasksId.map { ($0, t) } })
        // Use reduce to handle any duplicates safely — last writer wins.
        // Duplicates should not occur after RemindersManager deduplication,
        // but this prevents a crash if they do.
        let prevByRid: [String: TetherTask] = previous
            .compactMap { t in t.remindersId.map { ($0, t) } }
            .reduce(into: [:]) { $0[$1.0] = $1.1 }

        // Safety valve: Google returning 0 tasks could be a network failure.
        // We treat it as suspicious on the FIRST zero cycle only.
        // If Google returns 0 for TWO consecutive cycles, it's genuine — allow deletions.
        // This handles the case where the user deletes the last task.
        if googleTasks.isEmpty {
            consecutiveGoogleZero += 1
        } else {
            consecutiveGoogleZero = 0
        }
        let prevHadTasks     = !previous.isEmpty
        let googleSuspicious = googleTasks.isEmpty && prevHadTasks && consecutiveGoogleZero < 2

        if googleSuspicious {
            #if DEBUG
            print("SyncEngine: Google returned 0 tasks (cycle \(consecutiveGoogleZero)/2) — skipping deletions")
            #endif
        }

        // Track which Google IDs are handled in the Reminders loop
        // so the Google loop only processes unlinked tasks.
        var processedGids = Set<String>()

        for rTask in remindersTasks {
            guard let rid = rTask.remindersId else { continue }
            if let gid = idStore.googleId(for: rid) {
                processedGids.insert(gid)
                if let gTask = googleByGid[gid] {
                    let prev = prevByRid[rid]

                    if let prev {
                        let rChanged = rTask.isCompleted != prev.isCompleted
                                    || rTask.title       != prev.title
                                    || rTask.notes       != prev.notes
                                    || rTask.dueDate     != prev.dueDate
                        let gChanged = gTask.isCompleted != prev.isCompleted
                                    || gTask.title       != prev.title
                                    || gTask.notes       != prev.notes
                                    || gTask.dueDate     != prev.dueDate

                        if rChanged && !gChanged {
                            // Only Reminders changed → push to Google
                            diff.updateInGoogle.append(rTask)
                        } else if gChanged && !rChanged {
                            // Only Google changed → push to Reminders
                            diff.updateInReminders.append(gTask)
                        } else if rChanged && gChanged {
                            // Both changed → last-modified wins
                            if rTask.lastModified >= gTask.lastModified {
                                diff.updateInGoogle.append(rTask)
                            } else {
                                diff.updateInReminders.append(gTask)
                            }
                        }
                        // Neither changed → no-op
                    } else {
                        // No previous snapshot for this task yet.
                        // This happens on the first sync cycle after a task is linked.
                        // Small metadata differences (notes normalisation, date precision)
                        // between platforms cause spurious writes here.
                        // Safe to skip — the next cycle will have a proper prev
                        // and handle any genuine differences correctly.
                    }
                } else if prevByRid[rid] != nil {
                    if rTask.isCompleted {
                        // Completed task absent from Google — always intentional.
                        // Completed tasks don't vanish due to network failures.
                        // Bypass googleSuspicious entirely for completed tasks.
                        diff.deleteFromReminders.append(rid)
                    } else if remindersDeleteCandidates.contains(rid) && !googleSuspicious {
                        // Already a candidate AND Google not suspicious → fire deletion.
                        diff.deleteFromReminders.append(rid)
                    } else {
                        // First absence OR Google suspicious → become/stay a candidate.
                        // Always add to candidates regardless of googleSuspicious so
                        // the deletion fires on the very next non-suspicious cycle.
                        diff.addToRemindersDeleteCandidates.insert(rid)
                    }
                }
            } else {
                diff.addToGoogle.append(rTask)
            }
        }

        for gTask in googleTasks {
            guard let gid = gTask.googleTasksId else { continue }
            if processedGids.contains(gid) { continue }  // Already handled above
            if let rid = idStore.remindersId(for: gid) {
                if remindersByRid[rid] == nil {
                    if googleDeleteCandidates.contains(gid) {
                        // Already a candidate — fire deletion regardless of snapshot.
                        diff.deleteFromGoogle.append(gid)
                    } else if gTask.isCompleted {
                        // Completed task deleted from Reminders — always intentional.
                        // Transient fetch failures don't cause completed tasks to vanish.
                        // Skip the two-cycle guard and delete immediately.
                        diff.deleteFromGoogle.append(gid)
                    } else if prevByRid[rid] != nil {
                        // Incomplete task, first cycle of absence — become candidate.
                        // Wait one more cycle to confirm it's a genuine deletion.
                        diff.addToGoogleDeleteCandidates.insert(gid)
                    }
                }
            } else {
                // Never create a completed task in Reminders.
                // Completed tasks were intentionally removed from Reminders when done.
                // Re-creating them would undo the user's completion action.
                if !gTask.isCompleted {
                    diff.addToReminders.append(gTask)
                }
            }
        }

        return diff
    }

    // MARK: - Reconciliation
    //
    // Runs as the FIRST sync when the app has been off long enough that the
    // stored links can no longer be trusted (baseline missing, or last sync
    // older than reconciliationGap). Rules:
    //
    //   1. NO deletions on either side, ever. A task absent from one side
    //      might have been deleted intentionally weeks ago — but it might
    //      also be a re-created duplicate or a transient fetch gap. Genuine
    //      deletions still propagate, one cycle later, via the normal
    //      candidate system once a fresh baseline exists.
    //   2. Links whose Google side vanished are re-pointed at an unlinked
    //      Google task with the same title when one exists — this heals the
    //      common "deleted and re-typed while rearranging" case without
    //      creating duplicates.
    //   3. Linked pairs whose content differs are resolved by real
    //      modification timestamps (EKReminder.lastModifiedDate vs Google's
    //      updated field) — newer side wins, regardless of platform.
    //   4. Everything unlinked is merged additively.
    //
    // Worst case after a very long gap is a resurrected or duplicated task
    // the user deletes once by hand — never silent data loss.

    // Re-points links whose Google side no longer exists at an unlinked
    // Google task with an identical title and completion state, when
    // available. Mutates IDStore directly.
    @MainActor
    private func repairLinks(
        remindersTasks: [TetherTask],
        googleTasks:    [TetherTask]
    ) {
        let googleByGid = Dictionary(uniqueKeysWithValues:
            googleTasks.compactMap { t in t.googleTasksId.map { ($0, t) } })

        // Google tasks not currently linked to any reminder.
        var unmatchedGoogle = googleTasks.filter { gTask in
            guard let gid = gTask.googleTasksId else { return false }
            return idStore.remindersId(for: gid) == nil
        }

        for rTask in remindersTasks {
            guard let rid = rTask.remindersId else { continue }
            // Only repair dead links — a link is dead when its Google task
            // is absent from the fetch. Live links are left untouched.
            if let gid = idStore.googleId(for: rid), googleByGid[gid] != nil { continue }

            if let matchIdx = unmatchedGoogle.firstIndex(where: {
                $0.title == rTask.title && $0.isCompleted == rTask.isCompleted
            }) {
                let match = unmatchedGoogle.remove(at: matchIdx)
                if let newGid = match.googleTasksId {
                    idStore.link(remindersId: rid, googleId: newGid)
                    #if DEBUG
                    print("SyncEngine: re-linked '\(rTask.title)' to re-created Google task")
                    #endif
                }
            }
        }
    }

    // Builds a deletion-free diff: timestamp conflict resolution for linked
    // pairs, additive merge for everything else. Run after repairLinks.
    @MainActor
    private func buildReconciliationDiff(
        remindersTasks: [TetherTask],
        googleTasks:    [TetherTask]
    ) -> SyncDiff {
        var diff = SyncDiff()

        let googleByGid = Dictionary(uniqueKeysWithValues:
            googleTasks.compactMap { t in t.googleTasksId.map { ($0, t) } })

        var linkedGids = Set<String>()

        for rTask in remindersTasks {
            guard let rid = rTask.remindersId else { continue }

            if let gid = idStore.googleId(for: rid) {
                linkedGids.insert(gid)
                if let gTask = googleByGid[gid] {
                    // Linked pair present on both sides — content conflict
                    // resolved by real modification timestamps, newer wins.
                    if rTask != gTask {
                        if rTask.lastModified >= gTask.lastModified {
                            diff.updateInGoogle.append(rTask)
                        } else {
                            diff.updateInReminders.append(gTask)
                        }
                    }
                }
                // Dead link with no re-created match: leave both the task
                // and the link alone. If the other side was deliberately
                // deleted, the normal candidate system propagates it safely
                // over the next cycles — with a fresh baseline behind it.
            } else {
                // Never linked — push to Google.
                diff.addToGoogle.append(rTask)
            }
        }

        for gTask in googleTasks {
            guard let gid = gTask.googleTasksId,
                  !linkedGids.contains(gid),
                  idStore.remindersId(for: gid) == nil else { continue }
            // Unlinked Google task — mirror to Reminders unless completed
            // (re-creating a finished task would undo the user's action).
            if !gTask.isCompleted {
                diff.addToReminders.append(gTask)
            }
        }

        return diff
    }

    // MARK: - Apply Diff

    @MainActor
    private func applyDiff(_ diff: SyncDiff) async {
        for task in diff.addToReminders {
            let remindersId = remindersManager.createTask(
                title:   task.title,
                dueDate: task.dueDate,
                notes:   task.notes,
                url:     task.url
            )
            if let remindersId, let gid = task.googleTasksId {
                idStore.link(remindersId: remindersId, googleId: gid)
            }
        }

        for task in diff.addToGoogle {
            guard let rid = task.remindersId else { continue }
            await withCheckedContinuation { continuation in
                googleTasksManager.createTask(
                    title:   task.title,
                    notes:   task.notes,
                    dueDate: task.dueDate,
                    url:     task.url
                ) { [weak self] gid in
                    if let gid { self?.idStore.link(remindersId: rid, googleId: gid) }
                    continuation.resume()
                }
            }
        }

        for task in diff.updateInGoogle {
            guard let rid = task.remindersId,
                  let gid = idStore.googleId(for: rid) else { continue }
            googleTasksManager.updateTask(
                taskId:      gid,
                title:       task.title,
                notes:       task.notes,
                isCompleted: task.isCompleted,
                dueDate:     task.dueDate
            )
            if let reminder = remindersManager.fetchTask(by: rid),
               reminder.isCompleted != task.isCompleted {
                remindersManager.updateTask(
                    reminder,
                    title:       task.title,
                    notes:       task.notes,
                    isCompleted: task.isCompleted,
                    dueDate:     task.dueDate
                )
            }
        }

        // Update in Reminders (change originated in Google Tasks)
        for gTask in diff.updateInReminders {
            guard let gid = gTask.googleTasksId,
                  let rid = idStore.remindersId(for: gid),
                  let reminder = remindersManager.fetchTask(by: rid) else { continue }
            remindersManager.updateTask(
                reminder,
                title:       gTask.title,
                notes:       gTask.notes,
                isCompleted: gTask.isCompleted,
                dueDate:     gTask.dueDate
            )
        }

        for rid in diff.deleteFromReminders {
            if let reminder = remindersManager.fetchTask(by: rid) {
                remindersManager.deleteTask(reminder)
            }
            idStore.unlink(remindersId: rid)
        }

        for gid in diff.deleteFromGoogle {
            googleTasksManager.deleteTask(taskId: gid)
            if let rid = idStore.remindersId(for: gid) {
                idStore.unlink(remindersId: rid)
            }
        }
    }

    // MARK: - Merge & Sort

    @MainActor
    private func buildMergedList(
        remindersTasks: [TetherTask],
        googleTasks:    [TetherTask]
    ) async -> [TetherTask] {
        let googleByGid = Dictionary(uniqueKeysWithValues:
            googleTasks.compactMap { t in t.googleTasksId.map { ($0, t) } })

        var result: [TetherTask] = []
        for var rTask in remindersTasks {
            guard let rid = rTask.remindersId else { continue }
            if let gid = idStore.googleId(for: rid),
               let gTask = googleByGid[gid] {
                rTask.googleTasksId  = gid
                rTask.parentGoogleId = gTask.parentGoogleId
                rTask.url            = rTask.url ?? gTask.url
                rTask.source         = .both
            }
            result.append(rTask)
        }
        return result
    }

    @MainActor
    private func sortedByOrder(_ tasks: [TetherTask]) -> [TetherTask] {
        func pos(_ t: TetherTask) -> Int {
            t.remindersId.map { idStore.position(of: $0) } ?? Int.max
        }

        // Separate top-level tasks from subtasks
        let parents  = tasks.filter { $0.parentGoogleId == nil }
        let subtasks = tasks.filter { $0.parentGoogleId != nil }

        // Sort parents: incomplete first by position, completed last
        let incompleteParents = parents.filter { !$0.isCompleted }.sorted { pos($0) < pos($1) }
        let completedParents  = parents.filter {  $0.isCompleted }.sorted { pos($0) < pos($1) }

        // Build result: each parent followed immediately by its subtasks
        var result: [TetherTask] = []
        for parent in incompleteParents + completedParents {
            result.append(parent)
            let children = subtasks.filter { $0.parentGoogleId == parent.googleTasksId }
            let incompleteChildren = children.filter { !$0.isCompleted }
            let completedChildren  = children.filter {  $0.isCompleted }
            result.append(contentsOf: incompleteChildren + completedChildren)
        }

        // Orphaned subtasks (parent not in list) go at the end
        let knownParentIds = Set(parents.compactMap { $0.googleTasksId })
        let orphans = subtasks.filter {
            guard let pid = $0.parentGoogleId else { return false }
            return !knownParentIds.contains(pid)
        }
        result.append(contentsOf: orphans)

        return result
    }

    // MARK: - Order Sync

    // Pushes the current display order to Google Tasks using the move endpoint.
    // Google Tasks positions tasks by reference to the previous task ID,
    // so we walk the incomplete tasks in order and move each one after the previous.
    @MainActor
    private func pushOrderToGoogle(tasks: [TetherTask]) async {
        let incomplete = tasks.filter { !$0.isCompleted }
        var previousGoogleId: String? = nil

        for task in incomplete {
            guard let rid = task.remindersId,
                  let gid = idStore.googleId(for: rid) else { continue }
            googleTasksManager.moveTask(taskId: gid, previousTaskId: previousGoogleId)
            previousGoogleId = gid
            // Small delay to avoid rate limiting
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }
    }

    // MARK: - Date Helper

    // Returns noon UTC for the LOCAL calendar date of the given time.
    // Critical: must use the LOCAL calendar to extract year/month/day,
    // not UTC — otherwise tasks appear on the wrong day for users east of UTC.
    // Example: 00:30 Budapest (UTC+1) = 23:30 UTC previous day.
    // UTC calendar gives yesterday; local calendar correctly gives today.
    private func noonUTC(for date: Date = Date()) -> Date {
        // Extract date components in the user's local timezone
        let local = Calendar.current.dateComponents([.year, .month, .day], from: date)
        // Store as noon UTC for consistent cross-platform comparison
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        return utcCal.date(from: DateComponents(
            timeZone: TimeZone(identifier: "UTC"),
            year: local.year, month: local.month, day: local.day, hour: 12
        )) ?? date
    }

    // Schedules a sync at the next local midnight so todayTasks re-evaluates
    // when the calendar day rolls over, without waiting for the next timer tick.
    private func scheduleMidnightRefresh() {
        let cal   = Calendar.current
        guard let tomorrow  = cal.date(byAdding: .day, value: 1, to: Date()),
              let midnight  = cal.date(bySettingHour: 0, minute: 0, second: 0, of: tomorrow)
        else { return }
        let delay = midnight.timeIntervalSinceNow
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { await self?.sync() }
            self?.scheduleMidnightRefresh()  // Reschedule for next midnight
        }
    }

    // MARK: - Instant UI Updates

    @MainActor
    func toggleTask(id: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].isCompleted.toggle()
        tasks[idx].lastModified = Date()
        let task      = tasks[idx]
        let completed = task.isCompleted
        guard let rid = task.remindersId else { return }

        let completedIds = Set(tasks.filter { $0.isCompleted }.compactMap { $0.remindersId })
        if completed {
            idStore.moveToEnd(remindersId: rid)
        } else {
            idStore.moveBeforeCompleted(remindersId: rid, completedIds: completedIds)
        }

        tasks            = sortedByOrder(tasks)
        previousSnapshot = tasks
        persistBaseline()

        // Update stats immediately so InsightPanel reflects the toggle without
        // waiting for the next sync cycle.
        let todayAllAfterToggle = todayTasks
        statsStore.record(
            total:     todayAllAfterToggle.count,
            completed: todayAllAfterToggle.filter { $0.isCompleted }.count
        )
        if todayAllAfterToggle.isEmpty { statsStore.clearToday() }

        Task { @MainActor [weak self] in
            guard let self else { return }
            if let reminder = remindersManager.fetchTask(by: rid) {
                remindersManager.updateTask(
                    reminder,
                    title:       task.title,
                    notes:       task.notes,
                    isCompleted: completed,
                    dueDate:     task.dueDate
                )
            }
            if let gid = idStore.googleId(for: rid) {
                googleTasksManager.updateTask(
                    taskId:      gid,
                    title:       task.title,
                    notes:       task.notes,
                    isCompleted: completed,
                    dueDate:     task.dueDate
                )
            }
        }
    }

    @MainActor
    func addTask(title: String) {
        let dueDate = noonUTC()
        let tempId  = UUID().uuidString

        let task = TetherTask(
            id:            tempId,
            remindersId:   nil,
            googleTasksId: nil,
            title:         title,
            notes:         nil,
            isCompleted:   false,
            dueDate:       dueDate,
            url:           nil,
            lastModified:  Date(),
            source:        .both
        )
        tasks.insert(task, at: 0)
        previousSnapshot = tasks
        persistBaseline()

        Task { @MainActor [weak self] in
            guard let self else { return }

            let remindersId = await Task { @MainActor in
                self.remindersManager.createTask(
                    title:   title,
                    dueDate: dueDate,
                    notes:   nil
                )
            }.value

            guard let remindersId else { return }

            if let idx = tasks.firstIndex(where: { $0.id == tempId }) {
                tasks[idx].remindersId = remindersId
            }
            idStore.insertAtTop(remindersId: remindersId, completedIds: [])

            await withCheckedContinuation { continuation in
                self.googleTasksManager.createTask(
                    title:   title,
                    notes:   nil,
                    dueDate: dueDate,
                    url:     nil
                ) { [weak self] gid in
                    if let gid {
                        self?.idStore.link(remindersId: remindersId, googleId: gid)
                        Task { @MainActor in
                            if let idx = self?.tasks.firstIndex(where: { $0.id == tempId }) {
                                self?.tasks[idx].googleTasksId = gid
                            }
                        }
                    }
                    continuation.resume()
                }
            }

            previousSnapshot = tasks
            persistBaseline()
        }
    }

    @MainActor
    func deleteTask(id: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        let task = tasks.remove(at: idx)
        previousSnapshot = tasks
        persistBaseline()

        let todayAllAfterDelete = todayTasks
        statsStore.record(
            total:     todayAllAfterDelete.count,
            completed: todayAllAfterDelete.filter { $0.isCompleted }.count
        )
        if todayAllAfterDelete.isEmpty { statsStore.clearToday() }

        Task { @MainActor [weak self] in
            guard let self else { return }
            if let rid = task.remindersId {
                if let reminder = remindersManager.fetchTask(by: rid) {
                    remindersManager.deleteTask(reminder)
                }
                if let gid = idStore.googleId(for: rid) {
                    googleTasksManager.deleteTask(taskId: gid)
                }
                idStore.unlink(remindersId: rid)
            }
        }
    }

    // MARK: - Today Filter

    var todayTasks: [TetherTask] {
        let todayNoon = noonUTC()
        let tomorrow  = todayNoon + 86400
        return tasks.filter { task in
            guard let due = task.dueDate else { return false }
            // Only show tasks due today — completed or incomplete.
            // Overdue incomplete tasks are excluded (they are in the past).
            return due >= todayNoon && due < tomorrow
        }
    }

    // MARK: - Last Sync Text

    var lastSyncText: String {
        guard let date = lastSyncAt else {
            return String(localized: "sync.last.never")
        }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
