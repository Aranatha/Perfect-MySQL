// swift-tools-version:5.1
//  Package.swift
//  Perfect-MySQL
//
//  Created by Kyle Jessup on 3/22/16.
//	Copyright (C) 2016 PerfectlySoft, Inc.
//
//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2016 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
// See http://perfect.org/licensing.html for license information
//
//===----------------------------------------------------------------------===//
//

import PackageDescription

#if os(macOS)
let clientPackage = "https://github.com/PerfectlySoft/Perfect-mysqlclient.git"
#else
let clientPackage = "https://github.com/Aranatha/Perfect-mysqlclient-Linux.git"
#endif

let package = Package(
	name: "PerfectMySQL",
    platforms: [
        .macOS(.v10_15),
    ],
	products: [
		.library(name: "PerfectMySQL", targets: ["PerfectMySQL"])
	],
	dependencies: [
        .package(url: "https://github.com/Aranatha/Perfect-CRUD.git", .branch("master")),
		.package(url: clientPackage, from: "2.0.0"),
		],
	targets: [
		.target(name: "PerfectMySQL", dependencies: ["PerfectCRUD"]),
		.testTarget(name: "PerfectMySQLTests", dependencies: ["PerfectMySQL"])
	]
)
