//
//  PackageState.swift
//  Asspp
//
//  Created by qaq on 9/15/25.
//

import Foundation

struct PackageState: Codable, Hashable, Equatable {
    enum Status: String, Codable, Equatable, Hashable {
        case pending
        case downloading
        case processing
        case paused
        case completed
        case failed

        var title: String {
            switch self {
            case .pending: "等待开始"
            case .downloading: "正在下载"
            case .processing: "正在整理安装包"
            case .paused: "已暂停"
            case .completed: "下载完成"
            case .failed: "下载失败"
            }
        }
    }

    var status: Status = .pending
    var percent: Double = 0 {
        didSet { assert(percent >= 0 && percent <= 1) }
    }

    var error: String? = nil {
        didSet {
            if error != nil {
                status = .failed
            }
        }
    }

    var speed: String = ""
}

extension PackageState {
    mutating func start() {
        status = .pending
        error = nil
    }

    mutating func resetIfNotCompleted() {
        guard [.pending, .downloading, .processing].contains(status) else { return }
        status = .paused
    }

    mutating func complete() {
        status = .completed
        percent = 1
        speed = ""
        error = nil
    }
}

