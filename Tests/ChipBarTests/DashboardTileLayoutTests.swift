import Foundation
import Testing
@testable import ChipBar

struct DashboardTileLayoutTests {
    @Test func defaultLayoutKeepsOriginalTileProportions() {
        let arrangement = DashboardTileArrangement()
        #expect(arrangement.visible == DashboardTile.allCases)
        #expect(DashboardTile.powerTrend.columns == 6)
        #expect(DashboardTile.cpu.columns == 2)
        #expect(DashboardTile.gpu.columns == 2)
        #expect(DashboardTile.memory.columns == 2)
        #expect(DashboardTile.cpuCores.columns == 6)
        #expect(DashboardTile.fan.columns == 3)
        #expect(DashboardTile.ane.columns == 3)
        #expect(DashboardTile.storage.columns == 6)
        #expect(DashboardTile.powerSupply.columns == 6)
        #expect(DashboardTile.applications.columns == 6)
        #expect(DashboardTile.cluster.columns == 6)
    }

    @Test func corruptOrOldPreferencesCannotLoseModulesOrDuplicateTiles() {
        let arrangement = DashboardTileArrangement(
            savedOrder: ["gpu", "gpu", "usbOutput", "unknown", "cpu"],
            savedHidden: ["ane", "ane", "unknown"])
        #expect(arrangement.order.count == DashboardTile.allCases.count)
        #expect(Set(arrangement.order).count == DashboardTile.allCases.count)
        #expect(arrangement.order.prefix(2) == [.gpu, .cpu])
        #expect(arrangement.hidden == [.ane])
    }

    @Test func draggingReordersAndNeighboringTilesFillOpenSlots() {
        var arrangement = DashboardTileArrangement()
        arrangement.move(.memory, before: .cpu)
        #expect(arrangement.visible[1] == .memory)
        #expect(arrangement.visible[2] == .cpu)
        #expect(arrangement.visible[3] == .gpu)
        arrangement.move(.powerTrend, before: .applications)
        #expect(arrangement.visible.last == .cluster)
        #expect(arrangement.visible[arrangement.visible.count - 2] == .applications)
        #expect(arrangement.visible[arrangement.visible.count - 3] == .powerTrend)
    }

    @Test func lastDropSlotMovesTileToExactEnd() {
        var arrangement = DashboardTileArrangement()
        arrangement.moveToEnd(.powerTrend)
        #expect(arrangement.visible.last == .powerTrend)
        #expect(arrangement.visible.first == .cpu)
        #expect(Set(arrangement.visible).count == DashboardTile.allCases.count)
    }

    @Test func longPressLiftAndLandingReturnToIdleState() {
        let suite = "chipbar.tile.motion.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DashboardTileLayoutModel(defaults: defaults)
        let initialHeightRevision = model.layoutRevision
        model.select(.cpu, reduceMotion: true)
        #expect(model.editing)
        #expect(model.highlighted == .cpu)
        #expect(model.layoutRevision == initialHeightRevision)
        // Selecting a tile must not refit the AppKit glass panel.
        model.beginDrag(.cpu, at: CGPoint(x: 40, y: 40), reduceMotion: true)
        #expect(model.dragging == .cpu)
        #expect(model.layoutRevision == initialHeightRevision)
        model.move(.cpu, before: .gpu)
        model.finishDrop(reduceMotion: true)
        #expect(model.dragging == nil)
        #expect(model.highlighted == nil)
        #expect(!model.editing)
        // Exiting edit mode must NOT cancel the landing animation.
        #expect(model.settling == .cpu)
        #expect(model.layoutRevision == initialHeightRevision + 1)
    }

    @Test func editModePressMovesWithCursorAndReflowsOnlyOnTargetChange() {
        let suite = "chipbar.tile.pointer.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DashboardTileLayoutModel(defaults: defaults)
        model.tileFrames = [
            .cpu: CGRect(x: 0, y: 0, width: 100, height: 90),
            .gpu: CGRect(x: 110, y: 0, width: 100, height: 90)
        ]
        let revision = model.layoutRevision
        model.editing = true
        #expect(model.layoutRevision == revision)
        model.trackPress(.cpu, point: CGPoint(x: 50, y: 45), reduceMotion: true)
        #expect(model.dragging == .cpu)
        #expect(model.pointer.location == CGPoint(x: 50, y: 45))
        model.trackPress(.cpu, point: CGPoint(x: 180, y: 45), reduceMotion: true)
        #expect(model.pointer.location == CGPoint(x: 180, y: 45))
        #expect(model.arrangement.visible[1] == .gpu)
        #expect(model.arrangement.visible[2] == .cpu)
        #expect(model.layoutRevision == revision)
        model.endPress(.cpu, reduceMotion: true)
        #expect(model.dragging == nil)
        #expect(model.pointer.draggedTile == nil)
        #expect(!model.editing)
        #expect(model.settling == .cpu)
        #expect(model.layoutRevision == revision + 1)
        let reloaded = DashboardTileLayoutModel(defaults: defaults)
        #expect(reloaded.visible[1] == .gpu)
        #expect(reloaded.visible[2] == .cpu)
    }

    @Test func shortPressDoesNotAccidentallyStartTheTileEditor() {
        let suite = "chipbar.tile.click.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DashboardTileLayoutModel(defaults: defaults)
        model.trackPress(.cpu, point: CGPoint(x: 30, y: 30), reduceMotion: true)
        model.endPress(.cpu, reduceMotion: true)
        #expect(!model.editing)
        #expect(model.dragging == nil)
    }

    @Test func visibilityCanBeChangedWithoutDestroyingSavedPosition() {
        var arrangement = DashboardTileArrangement()
        arrangement.move(.ane, before: .cpu)
        arrangement.setVisible(.ane, false)
        #expect(!arrangement.visible.contains(.ane))
        arrangement.setVisible(.ane, true)
        #expect(arrangement.visible[1] == .ane)
    }

    @Test func layoutPersistsAndResetsInDedicatedDefaults() throws {
        let suite = "chipbar.tiles.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = DashboardTileLayoutModel(defaults: defaults)
        first.move(.fan, before: .powerTrend)
        first.setVisible(.storage, false)

        let second = DashboardTileLayoutModel(defaults: defaults)
        #expect(second.visible.first == .fan)
        #expect(!second.visible.contains(.storage))
        second.reset()

        let reset = DashboardTileLayoutModel(defaults: defaults)
        #expect(reset.visible == DashboardTile.allCases)
    }
}
