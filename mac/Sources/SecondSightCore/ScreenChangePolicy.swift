import Foundation

public enum ScreenChangePolicy {
    public static func isSignificant(
        previous: [UInt8]?,
        current: [UInt8],
        bytesPerCell: Int = 3,
        changedCellThreshold: Int = 30,
        changedCellFraction: Double = 0.12,
        overallMeanThreshold: Double = 14
    ) -> Bool {
        guard let previous else { return !current.isEmpty }
        guard bytesPerCell > 0,
              current.count == previous.count,
              current.count.isMultiple(of: bytesPerCell),
              !current.isEmpty
        else { return true }

        let cellCount = current.count / bytesPerCell
        var changedCells = 0
        var totalDifference = 0

        for cell in 0 ..< cellCount {
            let start = cell * bytesPerCell
            var cellDifference = 0
            for channel in 0 ..< bytesPerCell {
                let difference = abs(Int(current[start + channel]) - Int(previous[start + channel]))
                cellDifference += difference
                totalDifference += difference
            }
            if cellDifference / bytesPerCell >= changedCellThreshold {
                changedCells += 1
            }
        }

        let changedFraction = Double(changedCells) / Double(cellCount)
        let overallMean = Double(totalDifference) / Double(current.count)
        return changedFraction >= changedCellFraction || overallMean >= overallMeanThreshold
    }
}
