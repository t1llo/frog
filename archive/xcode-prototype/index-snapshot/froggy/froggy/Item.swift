//
//  Item.swift
//  froggy
//
//  Created by tillo on 21.02.2026.
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
