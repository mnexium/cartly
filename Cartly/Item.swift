//
//  Item.swift
//  Cartly
//
//  Created by Marius Ndini on 2/22/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
