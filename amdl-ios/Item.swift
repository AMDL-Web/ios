//
//  Item.swift
//  amdl-ios
//
//  Created by 梁杨峻玮 on 2026/7/4.
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
