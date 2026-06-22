import Foundation

/// Axis-aligned bounding box in image pixel coordinates. Mirrors the COCO `bbox`
/// `[x, y, w, h]` shape. `w` and `h` are always non-negative by construction
/// (BoxIntake normalizes negative-direction drags before this type is built).
struct BBox: Equatable, Hashable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    var coco: [Double] { [x, y, w, h] }
    var area: Double { w * h }
}

/// Three coarse PM-locked categories (AC #10). Maps to COCO `category_id` 1/2/3.
enum ClassCategory: Int, Codable, Equatable {
    case gi = 1
    case nogi = 2
    case ref = 3
}

/// Caller's intent to create OR update a box. The store is responsible for id
/// allocation, athlete binding, category resolution, and dictionary updates;
/// this struct only carries the geometry + optional override of the auto-assigned
/// instance id (set on edit, nil on create).
struct BBoxIntent: Equatable {
    /// nil = create new instance. Present = update existing instance with this id.
    var instanceId: Int?
    var rect: BBox

    init(instanceId: Int? = nil, rect: BBox) {
        self.instanceId = instanceId
        self.rect = rect
    }
}
