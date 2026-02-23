//import Combine
//import Foundation
//
//@MainActor
//final class ReceiptStore: ObservableObject {
//    @Published private(set) var receipts: [ReceiptEntry] = []
//
//    private let storageURL: URL
//
//    init(fileManager: FileManager = .default) {
//        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
//            ?? fileManager.temporaryDirectory
//        let appDirectory = baseDirectory.appendingPathComponent("Cartly", isDirectory: true)
//        self.storageURL = appDirectory.appendingPathComponent("receipts.json")
//
//        loadFromDisk(fileManager: fileManager, appDirectory: appDirectory)
//    }
//
//    func add(_ entry: ReceiptEntry) throws {
//        receipts.insert(entry, at: 0)
//        try persist()
//    }
//
//    func delete(at offsets: IndexSet) throws {
//        for index in offsets.sorted(by: >) {
//            receipts.remove(at: index)
//        }
//        try persist()
//    }
//
//    private func loadFromDisk(fileManager: FileManager, appDirectory: URL) {
//        do {
//            try fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)
//
//            guard fileManager.fileExists(atPath: storageURL.path) else {
//                receipts = []
//                return
//            }
//
//            let data = try Data(contentsOf: storageURL)
//            let decoder = JSONDecoder()
//            decoder.dateDecodingStrategy = .iso8601
//            receipts = try decoder.decode([ReceiptEntry].self, from: data)
//                .sorted(by: { $0.capturedAt > $1.capturedAt })
//        } catch {
//            receipts = []
//        }
//    }
//
//    private func persist() throws {
//        let encoder = JSONEncoder()
//        encoder.dateEncodingStrategy = .iso8601
//        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
//
//        let data = try encoder.encode(receipts)
//        try data.write(to: storageURL, options: .atomic)
//    }
//}
