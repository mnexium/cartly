import Foundation
import UIKit
@preconcurrency
import Vision

enum ReceiptOCRError: LocalizedError {
    case noImageData

    var errorDescription: String? {
        switch self {
        case .noImageData:
            return "Could not read image data for OCR."
        }
    }
}
