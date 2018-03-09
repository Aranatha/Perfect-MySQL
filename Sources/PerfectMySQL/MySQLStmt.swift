//
//  MySQLStmt.swift
//  PerfectMySQL
//
//  Created by Kyle Jessup on 2018-03-07.
//

#if os(Linux)
	import SwiftGlibc
#else
	import Darwin
#endif
import mysqlclient

/// handles mysql prepared statements
public final class MySQLStmt {
	private let ptr: UnsafeMutablePointer<MYSQL_STMT>
	private var paramBinds: UnsafeMutablePointer<MYSQL_BIND>?
	private var paramBindsOffset = 0
	var meta: UnsafeMutablePointer<MYSQL_RES>?
	
	/// initialize mysql statement structure
	public init(_ mysql: MySQL) {
		ptr = mysql_stmt_init(mysql.mysqlPtr)
	}
	
	deinit {
		clearBinds()
		if let meta = self.meta {
			mysql_free_result(meta)
		}
		mysql_stmt_close(ptr)
	}
	
	public func fieldNames() -> [Int: String] {
		let columnCount = Int(fieldCount())
		guard columnCount > 0 else {
			return [:]
		}
		var fieldDictionary = [Int: String]()
		let fields = mysql_fetch_fields(mysql_stmt_result_metadata(ptr))
		var i = 0
		while i != columnCount {
			fieldDictionary[i] = String(cString: fields![i].name)
			i += 1
		}
		return fieldDictionary
	}
	
	public enum FieldType {
		case integer,
		double,
		bytes,
		string,
		date,
		null
	}
	
	public struct FieldInfo {
		public let name: String
		public let type: FieldType
	}
	
	public func fieldInfo(index: Int) -> FieldInfo? {
		let fieldCount = Int(self.fieldCount())
		guard index < fieldCount else {
			return nil
		}
		guard let field = mysql_fetch_field_direct(meta, UInt32(index)) else {
			return nil
		}
		let f: MYSQL_FIELD = field.pointee
		return FieldInfo(name: String(validatingUTF8: f.name) ?? "invalid field name", type: mysqlTypeToFieldType(field))
	}
	
	func mysqlTypeToFieldType(_ field: UnsafeMutablePointer<MYSQL_FIELD>) -> FieldType {
		switch field.pointee.type {
		case MYSQL_TYPE_NULL:
			return .null
		case MYSQL_TYPE_FLOAT,
			 MYSQL_TYPE_DOUBLE:
			return .double
		case MYSQL_TYPE_TINY,
			 MYSQL_TYPE_SHORT,
			 MYSQL_TYPE_LONG,
			 MYSQL_TYPE_INT24,
			 MYSQL_TYPE_LONGLONG:
			return .integer
		case MYSQL_TYPE_TIMESTAMP,
			 MYSQL_TYPE_DATE,
			 MYSQL_TYPE_TIME,
			 MYSQL_TYPE_DATETIME,
			 MYSQL_TYPE_YEAR,
			 MYSQL_TYPE_NEWDATE:
			return .date
		case MYSQL_TYPE_DECIMAL,
			 MYSQL_TYPE_NEWDECIMAL:
			return .string
		case MYSQL_TYPE_TINY_BLOB,
			 MYSQL_TYPE_MEDIUM_BLOB,
			 MYSQL_TYPE_LONG_BLOB,
			 MYSQL_TYPE_BLOB:
			if (field.pointee.flags & UInt32(BINARY_FLAG)) != 0 {
				return .bytes
			}
			fallthrough
		default:
			return .string
		}
	}
	
	/// Possible status for fetch results
	public enum FetchResult {
		case OK, Error, NoData, DataTruncated
	}
	
	@available(*, deprecated)
	public func close() {}
	
	/// Resets the statement buffers in the server
	public func reset() {
		mysql_stmt_reset(ptr)
		resetBinds()
	}
	
	public func resetBinds() {
		let count = paramBindsOffset
		if let paramBinds = self.paramBinds, count > 0 {
			for i in 0..<count {
				let bind = paramBinds[i]
				switch bind.buffer_type.rawValue {
				case MYSQL_TYPE_DOUBLE.rawValue:
					bind.buffer.assumingMemoryBound(to: Double.self).deallocate(capacity: 1)
				case MYSQL_TYPE_LONGLONG.rawValue:
					if bind.is_unsigned == 1 {
						bind.buffer.assumingMemoryBound(to: UInt64.self).deallocate(capacity: 1)
					} else {
						bind.buffer.assumingMemoryBound(to: Int64.self).deallocate(capacity: 1)
					}
				case MYSQL_TYPE_VAR_STRING.rawValue,
					 MYSQL_TYPE_DATE.rawValue,
					 MYSQL_TYPE_DATETIME.rawValue:
					bind.buffer.assumingMemoryBound(to: Int8.self).deallocate(capacity: Int(bind.buffer_length))
				case MYSQL_TYPE_LONG_BLOB.rawValue,
					 MYSQL_TYPE_NULL.rawValue:
					()
				default:
					assertionFailure("Unhandled MySQL type \(bind.buffer_type)")
				}
				if bind.length != nil {
					bind.length.deallocate(capacity: 1)
				}
				paramBinds[i] = MYSQL_BIND()
			}
			paramBindsOffset = 0
		}
	}
	
	public func clearBinds() {
		let count = paramBindsOffset
		if count > 0, nil != paramBinds {
			resetBinds()
			paramBinds?.deallocate(capacity: count)
			paramBinds = nil
			paramBindsOffset = 0
		}
	}
	
	/// Free the resources allocated to a statement handle
	public func freeResult() {
		mysql_stmt_free_result(ptr)
	}
	
	/// Returns the error number for the last statement execution
	public func errorCode() -> UInt32 {
		return mysql_stmt_errno(ptr)
	}
	
	/// Returns the error message for the last statement execution
	public func errorMessage() -> String {
		return String(validatingUTF8: mysql_stmt_error(ptr)) ?? ""
	}
	
	/// Prepares an SQL statement string for execution
	public func prepare(statement query: String) -> Bool {
		let utf8Chars = query.utf8
		let r = mysql_stmt_prepare(ptr, query, UInt(utf8Chars.count))
		guard r == 0 else {
			return false
		}
		if let m = meta {
			mysql_free_result(m)
		}
		meta = mysql_stmt_result_metadata(ptr)
		let count = paramCount()
		if count > 0 {
			paramBinds = UnsafeMutablePointer<MYSQL_BIND>.allocate(capacity: count)
			let initBind = MYSQL_BIND()
			for i in 0..<count {
				paramBinds?.advanced(by: i).initialize(to: initBind)
			}
		}
		return true
	}
	
	/// Executes a prepared statement, binding parameters if needed
	public func execute() -> Bool {
		if paramBindsOffset > 0 {
			guard let paramBinds = self.paramBinds,
				0 == mysql_stmt_bind_param(ptr, paramBinds) else {
					return false
			}
		}
		let r = mysql_stmt_execute(ptr)
		return r == 0
	}
	
	/// returns current results
	public func results() -> MySQLStmt.Results {
		return Results(self)
	}
	
	/// Fetches the next row of data from a result set and returns status
	public func fetch() -> FetchResult {
		let r = mysql_stmt_fetch(ptr)
		switch r {
		case 0:
			return .OK
		case 1:
			return .Error
		case MYSQL_NO_DATA:
			return .NoData
		case MYSQL_DATA_TRUNCATED:
			return .DataTruncated
		default:
			return .Error
		}
	}
	
	/// Returns the row count from a buffered statement result set
	public func numRows() -> UInt {
		return UInt(mysql_stmt_num_rows(ptr))
	}
	
	/// Returns the number of rows changed, deleted, or inserted by prepared UPDATE, DELETE, or INSERT statement
	public func affectedRows() -> UInt {
		return UInt(mysql_stmt_affected_rows(ptr))
	}
	
	/// Returns the ID generated for an AUTO_INCREMENT column by a prepared statement
	public func insertId() -> UInt {
		return UInt(mysql_stmt_insert_id(ptr))
	}
	
	/// Returns the number of result columns for the most recent statement
	public func fieldCount() -> UInt {
		return UInt(mysql_stmt_field_count(ptr))
	}
	
	/// Returns/initiates the next result in a multiple-result execution
	public func nextResult() -> Int {
		let r = mysql_stmt_next_result(ptr)
		return Int(r)
	}
	
	/// Seeks to an arbitrary row number in a statement result set
	public func dataSeek(offset: Int) {
		mysql_stmt_data_seek(ptr, my_ulonglong(offset))
	}
	
	/// Returns the number of parameters in a prepared statement
	public func paramCount() -> Int {
		let r = mysql_stmt_param_count(ptr)
		return Int(r)
	}
	
	private func allocated(_ a: [UInt8]) -> UnsafeMutableRawBufferPointer? {
		let buffer = UnsafeMutableRawBufferPointer.allocate(count: a.count)
		buffer.copyBytes(from: a)
		return buffer
	}
	
	private func allocated(_ s: String) -> UnsafeMutableRawBufferPointer? {
		let utf8 = Array(s.utf8) + [0]
		return allocated(utf8)
	}
	
	private func allocated(_ b: UnsafePointer<Int8>, length: Int) -> UnsafeMutableRawBufferPointer? {
		let buffer = UnsafeMutableRawBufferPointer.allocate(count: length)
		memcpy(buffer.baseAddress, b, length)
		return buffer
	}
	
	func bindParam(_ s: String, type: enum_field_types) {
		guard let allocd = allocated(s) else {
			return
		}
		paramBinds?[paramBindsOffset].buffer_type = type
		paramBinds?[paramBindsOffset].buffer_length = UInt(allocd.count-1)
		paramBinds?[paramBindsOffset].length = UnsafeMutablePointer<UInt>.allocate(capacity: 1)
		paramBinds?[paramBindsOffset].length.initialize(to: UInt(allocd.count-1))
		paramBinds?[paramBindsOffset].buffer = allocd.baseAddress
		
		paramBindsOffset += 1
	}
	
	/// create Double parameter binding
	public func bindParam(_ d: Double) {
		paramBinds?[paramBindsOffset].buffer_type = MYSQL_TYPE_DOUBLE
		paramBinds?[paramBindsOffset].buffer_length = UInt(MemoryLayout<Double>.size)
		let a = UnsafeMutablePointer<Double>.allocate(capacity: 1)
		a.initialize(to: d)
		paramBinds?[paramBindsOffset].buffer = UnsafeMutableRawPointer(a)
		
		paramBindsOffset += 1
	}
	
	/// create Int parameter binding
	public func bindParam(_ i: Int) {
		paramBinds?[paramBindsOffset].buffer_type = MYSQL_TYPE_LONGLONG
		paramBinds?[paramBindsOffset].buffer_length = UInt(MemoryLayout<Int64>.size)
		let a = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
		a.initialize(to: Int64(i))
		paramBinds?[paramBindsOffset].buffer = UnsafeMutableRawPointer(a)
		
		paramBindsOffset += 1
	}
	
	/// create UInt64 parameter binding
	public func bindParam(_ i: UInt64) {
		paramBinds?[paramBindsOffset].buffer_type = MYSQL_TYPE_LONGLONG
		paramBinds?[paramBindsOffset].buffer_length = UInt(MemoryLayout<UInt64>.size)
		let a = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
		a.initialize(to: UInt64(i))
		paramBinds?[paramBindsOffset].is_unsigned = 1
		paramBinds?[paramBindsOffset].buffer = UnsafeMutableRawPointer(a)
		
		paramBindsOffset += 1
	}
	
	/// create String parameter binding
	public func bindParam(_ s: String) {
		guard let allocd = allocated(s) else {
			return
		}
		paramBinds?[paramBindsOffset].buffer_type = MYSQL_TYPE_VAR_STRING
		paramBinds?[paramBindsOffset].buffer_length = UInt(allocd.count-1)
		paramBinds?[paramBindsOffset].length = UnsafeMutablePointer<UInt>.allocate(capacity: 1)
		paramBinds?[paramBindsOffset].length.initialize(to: UInt(allocd.count-1))
		paramBinds?[paramBindsOffset].buffer = allocd.baseAddress
		
		paramBindsOffset += 1
	}
	
	/// create String parameter binding
	public func bindParam(_ a: [UInt8]) {
		guard let allocd = allocated(a) else {
			return
		}
		paramBinds?[paramBindsOffset].buffer_type = MYSQL_TYPE_LONG_BLOB
		paramBinds?[paramBindsOffset].buffer_length = UInt(allocd.count)
		paramBinds?[paramBindsOffset].length = UnsafeMutablePointer<UInt>.allocate(capacity: 1)
		paramBinds?[paramBindsOffset].length.initialize(to: UInt(allocd.count))
		paramBinds?[paramBindsOffset].buffer = allocd.baseAddress
		
		paramBindsOffset += 1
	}
	
	/// create Blob parameter binding
	/// The memory for this bind must remain valid until the statement is dead/resets
	public func bindParam(_ b: UnsafePointer<Int8>, length: Int) {
		guard let allocd = allocated(b, length: length) else {
			return
		}
		paramBinds?[paramBindsOffset].buffer_type = MYSQL_TYPE_LONG_BLOB
		paramBinds?[paramBindsOffset].buffer_length = UInt(length)
		paramBinds?[paramBindsOffset].length = UnsafeMutablePointer<UInt>.allocate(capacity: 1)
		paramBinds?[paramBindsOffset].length.initialize(to: UInt(length))
		paramBinds?[paramBindsOffset].buffer = allocd.baseAddress
		
		paramBindsOffset += 1
	}
	
	/// create null parameter binding
	public func bindParam() {
		paramBinds?[paramBindsOffset].buffer_type = MYSQL_TYPE_NULL
		paramBinds?[paramBindsOffset].length = UnsafeMutablePointer<UInt>.allocate(capacity: 1)
		paramBindsOffset += 1
	}
	
	//commented out Iterator Protocol until next() function can be implemented tt 04272016
	//public final class Results: IteratorProtocol {
	
	/// manage results sets for MysqlStmt
	public final class Results: IteratorProtocol {
		let _UNSIGNED_FLAG = UInt32(UNSIGNED_FLAG)
		public typealias Element = [Any?]
		
		let stmt: MySQLStmt
		
		/// Field count for result set
		public let numFields: Int
		/// Row count for current set
		public var numRows: Int {
			return Int(stmt.numRows())
		}
		
		var meta: UnsafeMutablePointer<MYSQL_RES>? { return stmt.meta }
		let binds: UnsafeMutablePointer<MYSQL_BIND>
		
		let lengthBuffers: UnsafeMutablePointer<UInt>
		let isNullBuffers: UnsafeMutablePointer<my_bool>
		private var closed = false
		
		init(_ s: MySQLStmt) {
			stmt = s
			numFields = Int(stmt.fieldCount())
			binds = UnsafeMutablePointer<MYSQL_BIND>.allocate(capacity: numFields)
			lengthBuffers = UnsafeMutablePointer<UInt>.allocate(capacity: numFields)
			isNullBuffers = UnsafeMutablePointer<my_bool>.allocate(capacity: numFields)
			mysql_stmt_store_result(stmt.ptr)
			bind()
		}
		
		deinit {
			unbind()
			binds.deallocate(capacity: numFields)
			lengthBuffers.deallocate(capacity: numFields)
			isNullBuffers.deallocate(capacity: numFields)
		}
		
		public func fetchRow() -> Bool {
			let fetchRes = mysql_stmt_fetch(stmt.ptr)
			if fetchRes == MYSQL_NO_DATA || fetchRes == 1 {
				return false
			}
			return true
		}
		
		public func currentRow() -> [Any?]? {
			let r = (0..<numFields).map { self.valueForField($0) }
			return r
		}
		
		public func next() -> Element? {
			if !fetchRow() {
				return nil
			}
			return currentRow()
		}
		
		enum GeneralType {
			case integer(enum_field_types),
			double(enum_field_types),
			bytes(enum_field_types),
			string(enum_field_types),
			date(enum_field_types),
			null
		}
		
		func mysqlTypeToGeneralType(_ field: UnsafeMutablePointer<MYSQL_FIELD>) -> GeneralType {
			let type = field.pointee.type
			switch type {
			case MYSQL_TYPE_NULL:
				return .null
			case MYSQL_TYPE_FLOAT,
				 MYSQL_TYPE_DOUBLE:
				return .double(type)
			case MYSQL_TYPE_TINY,
				 MYSQL_TYPE_SHORT,
				 MYSQL_TYPE_LONG,
				 MYSQL_TYPE_INT24,
				 MYSQL_TYPE_LONGLONG:
				return .integer(type)
			case MYSQL_TYPE_TIMESTAMP,
				 MYSQL_TYPE_DATE,
				 MYSQL_TYPE_TIME,
				 MYSQL_TYPE_DATETIME,
				 MYSQL_TYPE_YEAR,
				 MYSQL_TYPE_NEWDATE:
				return .date(type)
			case MYSQL_TYPE_DECIMAL,
				 MYSQL_TYPE_NEWDECIMAL:
				return .string(type)
			case MYSQL_TYPE_TINY_BLOB,
				 MYSQL_TYPE_MEDIUM_BLOB,
				 MYSQL_TYPE_LONG_BLOB,
				 MYSQL_TYPE_BLOB:
				if ( (field.pointee.flags & UInt32(BINARY_FLAG)) != 0) {
					return .bytes(type)
				}
				fallthrough
			default:
				return .string(type)
			}
		}
		
		func mysqlTypeToGeneralType(_ type: enum_field_types) -> GeneralType {
			switch type {
			case MYSQL_TYPE_NULL:
				return .null
			case MYSQL_TYPE_FLOAT,
				 MYSQL_TYPE_DOUBLE:
				return .double(type)
			case MYSQL_TYPE_TINY,
				 MYSQL_TYPE_SHORT,
				 MYSQL_TYPE_LONG,
				 MYSQL_TYPE_INT24,
				 MYSQL_TYPE_LONGLONG:
				return .integer(type)
			case MYSQL_TYPE_TIMESTAMP,
				 MYSQL_TYPE_DATE,
				 MYSQL_TYPE_TIME,
				 MYSQL_TYPE_DATETIME,
				 MYSQL_TYPE_YEAR,
				 MYSQL_TYPE_NEWDATE:
				return .date(type)
			case MYSQL_TYPE_DECIMAL,
				 MYSQL_TYPE_NEWDECIMAL:
				return .string(type)
			case MYSQL_TYPE_TINY_BLOB,
				 MYSQL_TYPE_MEDIUM_BLOB,
				 MYSQL_TYPE_LONG_BLOB,
				 MYSQL_TYPE_BLOB:
				return .bytes(type)
			default:
				return .string(type)
			}
		}
		
		func bindField(_ field: UnsafeMutablePointer<MYSQL_FIELD>) -> MYSQL_BIND {
			let generalType = mysqlTypeToGeneralType(field)
			let bind = bindToType(generalType)
			return bind
		}
		
		func bindBuffer<T>(_ sourceBind: MYSQL_BIND, type: T) -> MYSQL_BIND {
			var bind = sourceBind
			bind.buffer = UnsafeMutableRawPointer(UnsafeMutablePointer<T>.allocate(capacity: 1))
			bind.buffer_length = UInt(MemoryLayout<T>.size)
			return bind
		}
		
		private func valueForField(_ n: Int) -> Any? {
			var bind = binds[n]
			guard bind.is_null.pointee == 0 else {
				return nil
			}
			let genType = mysqlTypeToGeneralType(bind.buffer_type)
			let length = Int(bind.length.pointee)
			switch genType {
			case .double:
				switch bind.buffer_type {
				case MYSQL_TYPE_FLOAT:
					return bind.buffer.assumingMemoryBound(to: Float.self).pointee
				case MYSQL_TYPE_DOUBLE:
					return bind.buffer.assumingMemoryBound(to: Double.self).pointee
				default: return nil
				}
			case .integer:
				if bind.is_unsigned == 1 {
					switch bind.buffer_type {
					case MYSQL_TYPE_LONGLONG:
						return bind.buffer.assumingMemoryBound(to: UInt64.self).pointee
					case MYSQL_TYPE_LONG, MYSQL_TYPE_INT24:
						return bind.buffer.assumingMemoryBound(to: UInt32.self).pointee
					case MYSQL_TYPE_SHORT:
						return bind.buffer.assumingMemoryBound(to: UInt16.self).pointee
					case MYSQL_TYPE_TINY:
						return bind.buffer.assumingMemoryBound(to: UInt8.self).pointee
					default: return nil
					}
				} else {
					switch bind.buffer_type {
					case MYSQL_TYPE_LONGLONG:
						return bind.buffer.assumingMemoryBound(to: Int64.self).pointee
					case MYSQL_TYPE_LONG, MYSQL_TYPE_INT24:
						return bind.buffer.assumingMemoryBound(to: Int32.self).pointee
					case MYSQL_TYPE_SHORT:
						return bind.buffer.assumingMemoryBound(to: Int16.self).pointee
					case MYSQL_TYPE_TINY:
						return bind.buffer.assumingMemoryBound(to: Int8.self).pointee
					default: return nil
					}
				}
			case .bytes:
				let raw = UnsafeMutablePointer<UInt8>.allocate(capacity: length)
				defer {
					raw.deallocate(capacity: length)
				}
				bind.buffer = UnsafeMutableRawPointer(raw)
				bind.buffer_length = UInt(length)
				let res = mysql_stmt_fetch_column(stmt.ptr, &bind, UInt32(n), 0)
				guard res == 0 else {
					return nil
				}
				let a = (0..<length).map { raw[$0] }
				return a
			case .string, .date:
				let raw = UnsafeMutablePointer<UInt8>.allocate(capacity: length)
				defer {
					raw.deallocate(capacity: length)
				}
				bind.buffer = UnsafeMutableRawPointer(raw)
				bind.buffer_length = UInt(length)
				let res = mysql_stmt_fetch_column(stmt.ptr, &bind, UInt32(n), 0)
				guard res == 0 else {
					return nil
				}
				let s = UTF8Encoding.encode(generator: GenerateFromPointer(from: raw, count: length))
				return s
			case .null:
				return nil
			}
		}
		
		/// Retrieve and process each row with the provided callback
		public func forEachRow(callback: (Element) -> ()) -> Bool {
			while let row = next() {
				callback(row)
			}
			return true
		}
		
		func bindToType(_ type: GeneralType) -> MYSQL_BIND {
			switch type {
			case .double(let s):
				return bindToIntegral(s)
			case .integer(let s):
				return bindToIntegral(s)
			case .bytes:
				return bindToBlob()
			case .string, .date:
				return bindToString()
			case .null:
				return bindToNull()
			}
		}
		
		func bindToBlob() -> MYSQL_BIND {
			var bind = MYSQL_BIND()
			bind.buffer_type = MYSQL_TYPE_LONG_BLOB
			return bind
		}
		
		func bindToString() -> MYSQL_BIND {
			var bind = MYSQL_BIND()
			bind.buffer_type = MYSQL_TYPE_VAR_STRING
			return bind
		}
		
		func bindToNull() -> MYSQL_BIND {
			var bind = MYSQL_BIND()
			bind.buffer_type = MYSQL_TYPE_NULL
			return bind
		}
		
		func bindToIntegral(_ type: enum_field_types) -> MYSQL_BIND {
			var bind = MYSQL_BIND()
			bind.buffer_type = type
			return bind
		}
		
		private func bind() {
			let scratch = UnsafeMutableRawPointer(UnsafeMutablePointer<Int8>.allocate(capacity: 0))
			for i in 0..<numFields {
				guard let field = mysql_fetch_field_direct(meta, UInt32(i)) else {
					continue
				}
				let f: MYSQL_FIELD = field.pointee
				var bind = bindField(field)
				bind.length = lengthBuffers.advanced(by: i)
				bind.length.initialize(to: 0)
				bind.is_null = isNullBuffers.advanced(by: i)
				bind.is_null.initialize(to: 0)
				
				let genType = mysqlTypeToGeneralType(field)
				switch genType {
				case .double:
					switch bind.buffer_type {
					case MYSQL_TYPE_FLOAT:
						bind = bindBuffer(bind, type: Float.self);
					case MYSQL_TYPE_DOUBLE:
						bind = bindBuffer(bind, type: Double.self);
					default: break
					}
				case .integer:
					if (f.flags & _UNSIGNED_FLAG) == _UNSIGNED_FLAG {
						bind.is_unsigned = 1
						switch bind.buffer_type {
						case MYSQL_TYPE_LONGLONG:
							bind = bindBuffer(bind, type: UInt64.self);
						case MYSQL_TYPE_LONG, MYSQL_TYPE_INT24:
							bind = bindBuffer(bind, type: UInt32.self);
						case MYSQL_TYPE_SHORT:
							bind = bindBuffer(bind, type: UInt16.self);
						case MYSQL_TYPE_TINY:
							bind = bindBuffer(bind, type: UInt8.self);
						default: break
						}
					} else {
						switch bind.buffer_type {
						case MYSQL_TYPE_LONGLONG:
							bind = bindBuffer(bind, type: Int64.self);
						case MYSQL_TYPE_LONG, MYSQL_TYPE_INT24:
							bind = bindBuffer(bind, type: Int32.self);
						case MYSQL_TYPE_SHORT:
							bind = bindBuffer(bind, type: Int16.self);
						case MYSQL_TYPE_TINY:
							bind = bindBuffer(bind, type: Int8.self);
						default: break
						}
					}
				case .bytes, .string, .date, .null:
					bind.buffer = scratch
					bind.buffer_length = 0
				}
				binds.advanced(by: i).initialize(to: bind)
			}
			mysql_stmt_bind_result(stmt.ptr, binds)
		}
		
		private func unbind() {
			for i in 0..<numFields {
				let bind = binds[i]
				let genType = mysqlTypeToGeneralType(bind.buffer_type)
				switch genType {
				case .double:
					switch bind.buffer_type {
					case MYSQL_TYPE_FLOAT:
						bind.buffer.assumingMemoryBound(to: Float.self).deallocate(capacity: 1)
					case MYSQL_TYPE_DOUBLE:
						bind.buffer.assumingMemoryBound(to: Double.self).deallocate(capacity: 1)
					default: break
					}
				case .integer:
					if bind.is_unsigned == 1 {
						switch bind.buffer_type {
						case MYSQL_TYPE_LONGLONG:
							bind.buffer.assumingMemoryBound(to: UInt64.self).deallocate(capacity: 1)
						case MYSQL_TYPE_LONG, MYSQL_TYPE_INT24:
							bind.buffer.assumingMemoryBound(to: UInt32.self).deallocate(capacity: 1)
						case MYSQL_TYPE_SHORT:
							bind.buffer.assumingMemoryBound(to: UInt16.self).deallocate(capacity: 1)
						case MYSQL_TYPE_TINY:
							bind.buffer.assumingMemoryBound(to: UInt8.self).deallocate(capacity: 1)
						default: break
						}
					} else {
						switch bind.buffer_type {
						case MYSQL_TYPE_LONGLONG:
							bind.buffer.assumingMemoryBound(to: Int64.self).deallocate(capacity: 1)
						case MYSQL_TYPE_LONG, MYSQL_TYPE_INT24:
							bind.buffer.assumingMemoryBound(to: Int32.self).deallocate(capacity: 1)
						case MYSQL_TYPE_SHORT:
							bind.buffer.assumingMemoryBound(to: Int16.self).deallocate(capacity: 1)
						case MYSQL_TYPE_TINY:
							bind.buffer.assumingMemoryBound(to: Int8.self).deallocate(capacity: 1)
						default: break
						}
					}
				case .bytes, .string, .date, .null:
					() // do nothing. these were cleaned right after use or not allocated at all
				}
			}
		}
	}
}
