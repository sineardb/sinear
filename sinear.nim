import strutils, os, times, algorithm, math, asynchttpserver, asyncdispatch, json, std/exitprocs
when not defined(windows):
  import posix

var captureOutput = false
var outputBuffer = ""

proc outp(args: varargs[string, `$`]) =
  var s = ""
  for a in args:
    s.add(a)
  if captureOutput:
    outputBuffer.add(s)
    outputBuffer.add("\n")
  else:
    echo s

type
  ColumnDef = object
    name: string
    typ: string

  TableSchema = object
    name: string
    columns: seq[ColumnDef]

  Row = object
    id: int
    values: seq[string]

  StatementType = enum
    stCreate, stInsert, stSelect, stSelectJoin, stSelectStrip, stAlias, stObject, stLookup, stUndo

  UndoObjectKind = enum
    uokTable, uokAlias, uokLookup

  ExprNodeKind = enum
    enkNum, enkVar, enkBinOp

  ExprNode = ref object
    case kind: ExprNodeKind
    of enkNum:
      numVal: float
    of enkVar:
      varName: string
    of enkBinOp:
      op: char
      left, right: ExprNode

  ComputedColumn = tuple[expr: ExprNode, alias: string]

  LookupRule = object
    targetTable: string
    targetField: string
    sourceTable: string
    sourceField: string
    noDup: bool
    rawLine: string

  Statement = object
    kind: StatementType
    targetTable: string
    joinTable: string
    joinCol1: string
    joinCol2: string
    hasWhere: bool
    whereCol: string
    whereOp: string
    whereVal: string
    hasSort: bool
    sortCol: string
    sortDesc: bool
    hasLimit: bool
    limitVal: int
    hasGather: bool
    gatherCol: string
    hasSum: bool
    sumCol: string
    isAutoId: bool
    aliasName: string
    objectTarget: string
    columnAliases: seq[tuple[orig: string, alias: string]]
    computedCols: seq[ComputedColumn]
    hideWhereColumn: bool
    lookupTargetField: string
    lookupSourceTable: string
    lookupSourceField: string
    lookupNoDup: bool
    undoObjectName: string
    undoKind: UndoObjectKind
    subStatement: ref Statement
    schemaToCreate: TableSchema
    rowToInsert: Row

  AliasView = object
    name: string
    rawQuery: string
    columnAliases: seq[tuple[orig: string, alias: string]]
    statement: Statement

  PrepareResult = enum
    prSuccess, prSyntaxError, prUnrecognizedStatement, prNegativeId, prTableNotFound, prTableAlreadyExists, prColumnNotFound, prInvalidDataType, prLookupNotFound, prDuplicateData, prObjectNotFound, prTableHasData, prAliasReferenced

  ExecuteResult = enum
    erSuccess, erTableFull

  Table = object
    schema: TableSchema
    rawCreateLine: string
    rows: seq[Row]

  Database = object
    tables: seq[Table]
    views: seq[AliasView]
    lookups: seq[LookupRule]

const LogFileName = "db.log"
const LockFileName = "db.lock"

when defined(windows):
  const STILL_ACTIVE: uint32 = 259
  const PROCESS_QUERY_LIMITED_INFORMATION: int32 = 0x1000

  proc winOpenProcess(desiredAccess: int32, inheritHandle: int32, processId: int32): pointer
    {.stdcall, dynlib: "kernel32", importc: "OpenProcess".}
  proc winGetExitCodeProcess(hProcess: pointer, lpExitCode: ptr uint32): int32
    {.stdcall, dynlib: "kernel32", importc: "GetExitCodeProcess".}
  proc winCloseHandle(hObject: pointer): int32
    {.stdcall, dynlib: "kernel32", importc: "CloseHandle".}

  proc isProcessAlive(pid: int): bool =
    if pid <= 0:
      return false
    let h = winOpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, int32(pid))
    if h == nil:
      return false
    var exitCode: uint32 = 0
    let ok = winGetExitCodeProcess(h, addr exitCode)
    discard winCloseHandle(h)
    if ok == 0:
      return false
    return exitCode == STILL_ACTIVE
else:
  proc isProcessAlive(pid: int): bool =
    if pid <= 0:
      return false
    try:
      return kill(Pid(pid), cint(0)) == 0
    except:
      return false

proc releaseLock() =
  try:
    if fileExists(LockFileName):
      removeFile(LockFileName)
  except:
    discard

proc acquireLock(): bool =
  if fileExists(LockFileName):
    var oldPid = -1
    try:
      oldPid = readFile(LockFileName).strip().parseInt()
    except:
      oldPid = -1
    if isProcessAlive(oldPid):
      return false
    else:
      try:
        removeFile(LockFileName)
      except:
        discard

  try:
    writeFile(LockFileName, $getCurrentProcessId())
  except:
    return false

  addExitProc(releaseLock)
  setControlCHook(proc() {.noconv.} =
    releaseLock()
    quit(0)
  )
  return true

proc requireSingleInstance() =
  if not acquireLock():
    echo "Error: sinear is already running on this host (file '", LockFileName, "' detected, owned by a still-active process)."
    echo "Only one instance (CLI or --server) may be active per host at a time."
    quit(1)

proc findTableIndex(db: Database, name: string): int =
  for i, t in db.tables:
    if t.schema.name.toLowerAscii() == name.toLowerAscii():
      return i
  return -1

proc findColumnIndex(table: Table, colName: string): int =
  if colName.toLowerAscii() == "id":
    return 0
  for i, col in table.schema.columns:
    if col.name.toLowerAscii() == colName.toLowerAscii():
      return i
  return -1

proc findColumnIndexExtended(table: Table, columnAliases: seq[tuple[orig: string, alias: string]], colName: string): int =
  let idx = findColumnIndex(table, colName)
  if idx != -1:
    return idx
  for mapping in columnAliases:
    if mapping.alias.toLowerAscii() == colName.toLowerAscii() or mapping.orig.toLowerAscii() == colName.toLowerAscii():
      return findColumnIndex(table, mapping.orig)
  return -1

proc getColumnValue(row: Row, table: Table, colIdx: int): string =
  if colIdx == 0:
    return $row.id
  else:
    let valIdx = colIdx - 1
    if valIdx >= 0 and valIdx < row.values.len:
      return row.values[valIdx]
    return ""

proc matchWhere(row: Row, table: Table, statement: Statement): bool =
  if not statement.hasWhere:
    return true
  let colIdx = findColumnIndexExtended(table, statement.columnAliases, statement.whereCol)
  if colIdx == -1:
    return true
  let val = getColumnValue(row, table, colIdx)
  let targetVal = statement.whereVal.strip(chars = {'\'', '"'})

  if statement.whereOp in ["%", "!%", "%!"]:
    case statement.whereOp
    of "%": return targetVal in val
    of "!%": return val.startsWith(targetVal)
    of "%!": return val.endsWith(targetVal)
    else: return false

  try:
    let f1 = val.parseFloat()
    let f2 = targetVal.parseFloat()
    case statement.whereOp
    of "=": return f1 == f2
    of "!=": return f1 != f2
    of "<": return f1 < f2
    of "<=": return f1 <= f2
    of ">": return f1 > f2
    of ">=": return f1 >= f2
    else: return false
  except ValueError:
    try:
      let n1 = val.parseInt()
      let n2 = targetVal.parseInt()
      case statement.whereOp
      of "=": return n1 == n2
      of "!=": return n1 != n2
      of "<": return n1 < n2
      of "<=": return n1 <= n2
      of ">": return n1 > n2
      of ">=": return n1 >= n2
      else: return false
    except ValueError:
      case statement.whereOp
      of "=": return val == targetVal
      of "!=": return val != targetVal
      of "<": return val < targetVal
      of "<=": return val <= targetVal
      of ">": return val > targetVal
      of ">=": return val >= targetVal
      else: return false

proc matchJoinWhere(r1: Row, t1: Table, r2: Row, t2: Table, t2Aliases: seq[tuple[orig: string, alias: string]], statement: Statement): bool =
  if not statement.hasWhere:
    return true
  
  var colVal = ""
  let c1 = findColumnIndexExtended(t1, statement.columnAliases, statement.whereCol)
  if c1 != -1:
    colVal = getColumnValue(r1, t1, c1)
  else:
    let c2 = findColumnIndexExtended(t2, t2Aliases, statement.whereCol)
    if c2 != -1:
      colVal = getColumnValue(r2, t2, c2)
    else:
      return true

  let targetVal = statement.whereVal.strip(chars = {'\'', '"'})

  if statement.whereOp in ["%", "!%", "%!"]:
    case statement.whereOp
    of "%": return targetVal in colVal
    of "!%": return colVal.startsWith(targetVal)
    of "%!": return colVal.endsWith(targetVal)
    else: return false

  try:
    let f1 = colVal.parseFloat()
    let f2 = targetVal.parseFloat()
    case statement.whereOp
    of "=": return f1 == f2
    of "!=": return f1 != f2
    of "<": return f1 < f2
    of "<=": return f1 <= f2
    of ">": return f1 > f2
    of ">=": return f1 >= f2
    else: return false
  except ValueError:
    try:
      let n1 = colVal.parseInt()
      let n2 = targetVal.parseInt()
      case statement.whereOp
      of "=": return n1 == n2
      of "!=": return n1 != n2
      of "<": return n1 < n2
      of "<=": return n1 <= n2
      of ">": return n1 > n2
      of ">=": return n1 >= n2
      else: return false
    except ValueError:
      case statement.whereOp
      of "=": return colVal == targetVal
      of "!=": return colVal != targetVal
      of "<": return colVal < targetVal
      of "<=": return colVal <= targetVal
      of ">": return colVal > targetVal
      of ">=": return colVal >= targetVal
      else: return false

proc formatComputedValue(v: float): string =
  if v == v.trunc() and abs(v) < 1e15:
    return $v.int
  return $v

proc resolveOperand(row: Row, table: Table, statement: Statement, name: string): string =
  try:
    discard name.parseFloat()
    return name
  except ValueError:
    let idx = findColumnIndexExtended(table, statement.columnAliases, name)
    if idx == -1:
      return ""
    return getColumnValue(row, table, idx)


proc tokenizeExpr(s: string): seq[string] =
  result = @[]
  var i = 0
  while i < s.len:
    let c = s[i]
    if c in {' ', '\t'}:
      i.inc()
    elif c in {'+', '-', '*', '/', '(', ')'}:
      result.add($c)
      i.inc()
    else:
      var j = i
      while j < s.len and s[j] notin {'+', '-', '*', '/', '(', ')', ' ', '\t'}:
        j.inc()
      if j > i:
        result.add(s[i ..< j])
      i = j

proc parseExprRec(tokens: seq[string], pos: var int): ExprNode

proc parseFactor(tokens: seq[string], pos: var int): ExprNode =
  if pos >= tokens.len:
    return ExprNode(kind: enkNum, numVal: 0.0)
  let tok = tokens[pos]
  if tok == "(":
    pos.inc()
    result = parseExprRec(tokens, pos)
    if pos < tokens.len and tokens[pos] == ")":
      pos.inc()
  else:
    pos.inc()
    try:
      let n = tok.parseFloat()
      result = ExprNode(kind: enkNum, numVal: n)
    except ValueError:
      result = ExprNode(kind: enkVar, varName: tok)

proc parseTerm(tokens: seq[string], pos: var int): ExprNode =
  result = parseFactor(tokens, pos)
  while pos < tokens.len and (tokens[pos] == "*" or tokens[pos] == "/"):
    let op = tokens[pos][0]
    pos.inc()
    let right = parseFactor(tokens, pos)
    result = ExprNode(kind: enkBinOp, op: op, left: result, right: right)

proc parseExprRec(tokens: seq[string], pos: var int): ExprNode =
  result = parseTerm(tokens, pos)
  while pos < tokens.len and (tokens[pos] == "+" or tokens[pos] == "-"):
    let op = tokens[pos][0]
    pos.inc()
    let right = parseTerm(tokens, pos)
    result = ExprNode(kind: enkBinOp, op: op, left: result, right: right)

proc parseExpression(exprStr: string): ExprNode =
  let tokens = tokenizeExpr(exprStr)
  var pos = 0
  result = parseExprRec(tokens, pos)

proc evalExprNode(node: ExprNode, row: Row, table: Table, statement: Statement): float =
  case node.kind
  of enkNum:
    return node.numVal
  of enkVar:
    let s = resolveOperand(row, table, statement, node.varName)
    return s.parseFloat()
  of enkBinOp:
    let l = evalExprNode(node.left, row, table, statement)
    let r = evalExprNode(node.right, row, table, statement)
    case node.op
    of '+': return l + r
    of '-': return l - r
    of '*': return l * r
    of '/':
      if r == 0.0:
        raise newException(ValueError, "division by zero")
      return l / r
    else:
      raise newException(ValueError, "unknown operator")

proc evalComputedColumn(row: Row, table: Table, statement: Statement, cc: ComputedColumn): string =
  try:
    let v = evalExprNode(cc.expr, row, table, statement)
    return formatComputedValue(v)
  except ValueError:
    return "N/A"

proc pad(s: string, width: int): string =
  if s.len >= width:
    return s
  return s & repeat(" ", width - s.len)

type GroupAggregate = object
  key: string
  sumVal: float
  count: int

proc printTableFiltered(table: Table, statement: Statement) =
  var matchingRows: seq[Row] = @[]
  for row in table.rows:
    if matchWhere(row, table, statement):
      matchingRows.add(row)

  if statement.hasGather:
    let gatherColIdx = findColumnIndexExtended(table, statement.columnAliases, statement.gatherCol)
    var groups: seq[GroupAggregate] = @[]

    var sumColIdx = -1
    if statement.hasSum:
      sumColIdx = findColumnIndexExtended(table, statement.columnAliases, statement.sumCol)

    for row in matchingRows:
      let key = getColumnValue(row, table, gatherColIdx)
      var valToAdd = 0.0
      if statement.hasSum and sumColIdx != -1:
        let sStr = getColumnValue(row, table, sumColIdx)
        try:
          valToAdd = sStr.parseFloat()
        except ValueError:
          discard

      var found = false
      for g in groups.mitems:
        if g.key == key:
          g.sumVal += valToAdd
          g.count.inc()
          found = true
          break
      if not found:
        groups.add(GroupAggregate(key: key, sumVal: valToAdd, count: 1))

    var headers: seq[string] = @[statement.gatherCol]
    if statement.hasSum:
      headers.add("sum(" & statement.sumCol & ")")
    else:
      headers.add("count")

    var formattedRows: seq[seq[string]] = @[]
    for g in groups:
      var rowVals = newSeq[string](headers.len)
      rowVals[0] = g.key
      if statement.hasSum:
        rowVals[1] = $g.sumVal
      else:
        rowVals[1] = $g.count
      formattedRows.add(rowVals)

    if statement.hasSort:
      let sortColLower = statement.sortCol.toLowerAscii()
      let sortIdx = if sortColLower == statement.gatherCol.toLowerAscii(): 0 else: 1
      formattedRows.sort(proc (a, b: seq[string]): int =
        let valA = a[sortIdx]
        let valB = b[sortIdx]
        var cmpRes = 0
        try:
          let f1 = valA.parseFloat()
          let f2 = valB.parseFloat()
          cmpRes = system.cmp(f1, f2)
        except ValueError:
          try:
            let n1 = valA.parseInt()
            let n2 = valB.parseInt()
            cmpRes = system.cmp(n1, n2)
          except ValueError:
            cmpRes = system.cmp(valA, valB)
        
        if statement.sortDesc:
          return -cmpRes
        else:
          return cmpRes
      )

    if statement.hasLimit and formattedRows.len > statement.limitVal:
      formattedRows = formattedRows[0 ..< statement.limitVal]

    var colWidths = newSeq[int](headers.len)
    for i, h in headers:
      colWidths[i] = h.len
    for rowVals in formattedRows:
      for i, val in rowVals:
        if val.len > colWidths[i]:
          colWidths[i] = val.len

    var headerLine = ""
    for i, h in headers:
      let w = colWidths[i]
      headerLine.add(pad(h, w) & " | ")

    var separatorLine = ""
    for c in headerLine:
      if c == '|':
        separatorLine.add('-')
      elif c == ' ':
        separatorLine.add(' ')
      else:
        separatorLine.add('-')

    outp headerLine
    outp separatorLine

    for rowVals in formattedRows:
      var line = ""
      for i, val in rowVals:
        let w = colWidths[i]
        line.add(pad(val, w) & " | ")
      outp line
    return

  var colIndices: seq[int] = @[]
  var headers: seq[string] = @[]

  if statement.columnAliases.len > 0:
    for mapping in statement.columnAliases:
      let idx = findColumnIndex(table, mapping.orig)
      if idx != -1:
        colIndices.add(idx)
        headers.add(mapping.alias)
  elif statement.computedCols.len == 0:
    for i in 0 ..< table.schema.columns.len:
      colIndices.add(i)
    for col in table.schema.columns:
      headers.add(col.name)

  if statement.hideWhereColumn and statement.hasWhere:
    var newColIndices: seq[int] = @[]
    var newHeaders: seq[string] = @[]
    for j, idx in colIndices:
      if table.schema.columns[idx].name.toLowerAscii() != statement.whereCol.toLowerAscii():
        newColIndices.add(idx)
        newHeaders.add(headers[j])
    colIndices = newColIndices
    headers = newHeaders

  for cc in statement.computedCols:
    headers.add(cc.alias)

  let numCols = headers.len
  if numCols == 0:
    return

  if statement.hasSort:
    let sortColIdx = findColumnIndexExtended(table, statement.columnAliases, statement.sortCol)
    if sortColIdx != -1:
      matchingRows.sort(proc (a, b: Row): int =
        let valA = getColumnValue(a, table, sortColIdx)
        let valB = getColumnValue(b, table, sortColIdx)
        var cmpRes = 0
        try:
          let f1 = valA.parseFloat()
          let f2 = valB.parseFloat()
          cmpRes = system.cmp(f1, f2)
        except ValueError:
          try:
            let n1 = valA.parseInt()
            let n2 = valB.parseInt()
            cmpRes = system.cmp(n1, n2)
          except ValueError:
            cmpRes = system.cmp(valA, valB)
        
        if statement.sortDesc:
          return -cmpRes
        else:
          return cmpRes
      )

  if statement.hasLimit and matchingRows.len > statement.limitVal:
    matchingRows = matchingRows[0 ..< statement.limitVal]

  var colWidths = newSeq[int](numCols)
  for i, h in headers:
    colWidths[i] = h.len

  var formattedRows: seq[seq[string]] = @[]
  for row in matchingRows:
    var rowVals = newSeq[string](numCols)
    for j, colIdx in colIndices:
      rowVals[j] = getColumnValue(row, table, colIdx)
    for k, cc in statement.computedCols:
      rowVals[colIndices.len + k] = evalComputedColumn(row, table, statement, cc)
    formattedRows.add(rowVals)

    for i, val in rowVals:
      if val.len > colWidths[i]:
        colWidths[i] = val.len

  var headerLine = ""
  for i, h in headers:
    let w = colWidths[i]
    headerLine.add(pad(h, w) & " | ")

  var separatorLine = ""
  for c in headerLine:
    if c == '|':
      separatorLine.add('-')
    elif c == ' ':
      separatorLine.add(' ')
    else:
      separatorLine.add('-')

  outp headerLine
  outp separatorLine

  for rowVals in formattedRows:
    var line = ""
    for i, val in rowVals:
      let w = colWidths[i]
      line.add(pad(val, w) & " | ")
    outp line

proc computeJoinRows(statement: Statement, db: Database, isStrip: bool = false): tuple[headers: seq[string], rows: seq[seq[string]]] =
  let t1Idx = findTableIndex(db, statement.targetTable)
  let t1 = db.tables[t1Idx]

  var t2Idx = findTableIndex(db, statement.joinTable)
  var v2Idx = -1
  for i, v in db.views:
    if v.name.toLowerAscii() == statement.joinTable.toLowerAscii():
      v2Idx = i
      break

  var t2: Table
  var t2Name = statement.joinTable
  var t2ColumnAliases: seq[tuple[orig: string, alias: string]] = @[]
  var t2Rows: seq[Row] = @[]

  if t2Idx != -1:
    t2 = db.tables[t2Idx]
    t2Rows = t2.rows
  else:
    if v2Idx != -1:
      let joinView = db.views[v2Idx]
      t2 = db.tables[findTableIndex(db, joinView.statement.targetTable)]
      t2Name = joinView.name
      t2ColumnAliases = joinView.columnAliases
      for r2 in t2.rows:
        if matchWhere(r2, t2, joinView.statement):
          t2Rows.add(r2)

  let c1Idx = findColumnIndexExtended(t1, statement.columnAliases, statement.joinCol1)
  let c2Idx = findColumnIndexExtended(t2, t2ColumnAliases, statement.joinCol2)

  let useProj = (statement.columnAliases.len > 0)
  var headers: seq[string] = @[]
  var projections: seq[tuple[isT1: bool, colIdx: int]] = @[]

  if useProj:
    for mapping in statement.columnAliases:
      headers.add(mapping.alias)
      let dotIdx = mapping.orig.find('.')
      if dotIdx != -1:
        let prefix = mapping.orig[0 ..< dotIdx]
        let colName = mapping.orig[dotIdx + 1 .. ^1]
        let prefixLower = prefix.toLowerAscii()
        if prefixLower == t1.schema.name.toLowerAscii() or prefixLower == statement.targetTable.toLowerAscii():
          let idx1 = findColumnIndex(t1, colName)
          projections.add((isT1: true, colIdx: (if idx1 != -1: idx1 else: 0)))
        elif prefixLower == t2Name.toLowerAscii() or prefixLower == statement.joinTable.toLowerAscii():
          let idx2 = findColumnIndex(t2, colName)
          projections.add((isT1: false, colIdx: (if idx2 != -1: idx2 else: 0)))
        else:
          let idx1 = findColumnIndex(t1, colName)
          if idx1 != -1:
            projections.add((isT1: true, colIdx: idx1))
          else:
            let idx2 = findColumnIndex(t2, colName)
            if idx2 != -1:
              projections.add((isT1: false, colIdx: idx2))
            else:
              projections.add((isT1: true, colIdx: 0))
      else:
        let idx1 = findColumnIndex(t1, mapping.orig)
        if idx1 != -1:
          projections.add((isT1: true, colIdx: idx1))
        else:
          let idx2 = findColumnIndex(t2, mapping.orig)
          if idx2 != -1:
            projections.add((isT1: false, colIdx: idx2))
          else:
            projections.add((isT1: true, colIdx: 0))
  else:
    for col in t1.schema.columns:
      headers.add(t1.schema.name & "." & col.name)
    if t2ColumnAliases.len > 0:
      for mapping in t2ColumnAliases:
        headers.add(t2Name & "." & mapping.alias)
    else:
      for col in t2.schema.columns:
        headers.add(t2Name & "." & col.name)

  let numCols = headers.len

  var joinedRows: seq[seq[string]] = @[]

  for r1 in t1.rows:
    let v1 = getColumnValue(r1, t1, c1Idx)
    var matched = false
    var matchedR2: Row

    for r2 in t2Rows:
      let v2 = getColumnValue(r2, t2, c2Idx)
      if v1 == v2:
        matched = true
        matchedR2 = r2
        break

    if isStrip:
      if not matched:
        if matchJoinWhere(r1, t1, Row(id: 0, values: @[]), t2, t2ColumnAliases, statement):
          var rowVals = newSeq[string](numCols)
          if useProj:
            for j, proj in projections:
              if proj.isT1:
                rowVals[j] = getColumnValue(r1, t1, proj.colIdx)
              else:
                rowVals[j] = ""
          else:
            var colIdxTracker = 0
            for i in 0 ..< t1.schema.columns.len:
              rowVals[colIdxTracker] = getColumnValue(r1, t1, i)
              colIdxTracker.inc()
            if t2ColumnAliases.len > 0:
              for mapping in t2ColumnAliases:
                rowVals[colIdxTracker] = ""
                colIdxTracker.inc()
            else:
              for i in 0 ..< t2.schema.columns.len:
                rowVals[colIdxTracker] = ""
                colIdxTracker.inc()
          joinedRows.add(rowVals)
    else:
      if matched:
        if matchJoinWhere(r1, t1, matchedR2, t2, t2ColumnAliases, statement):
          var rowVals = newSeq[string](numCols)
          if useProj:
            for j, proj in projections:
              if proj.isT1:
                rowVals[j] = getColumnValue(r1, t1, proj.colIdx)
              else:
                rowVals[j] = getColumnValue(matchedR2, t2, proj.colIdx)
          else:
            var colIdxTracker = 0
            for i in 0 ..< t1.schema.columns.len:
              rowVals[colIdxTracker] = getColumnValue(r1, t1, i)
              colIdxTracker.inc()
            if t2ColumnAliases.len > 0:
              for mapping in t2ColumnAliases:
                let colIdx = findColumnIndex(t2, mapping.orig)
                rowVals[colIdxTracker] = getColumnValue(matchedR2, t2, colIdx)
                colIdxTracker.inc()
            else:
              for i in 0 ..< t2.schema.columns.len:
                rowVals[colIdxTracker] = getColumnValue(matchedR2, t2, i)
                colIdxTracker.inc()
          joinedRows.add(rowVals)
      else:
        if matchJoinWhere(r1, t1, Row(id: 0, values: @[]), t2, t2ColumnAliases, statement):
          var rowVals = newSeq[string](numCols)
          if useProj:
            for j, proj in projections:
              if proj.isT1:
                rowVals[j] = getColumnValue(r1, t1, proj.colIdx)
              else:
                rowVals[j] = ""
          else:
            var colIdxTracker = 0
            for i in 0 ..< t1.schema.columns.len:
              rowVals[colIdxTracker] = getColumnValue(r1, t1, i)
              colIdxTracker.inc()
            if t2ColumnAliases.len > 0:
              for mapping in t2ColumnAliases:
                rowVals[colIdxTracker] = ""
                colIdxTracker.inc()
            else:
              for i in 0 ..< t2.schema.columns.len:
                rowVals[colIdxTracker] = ""
                colIdxTracker.inc()
          joinedRows.add(rowVals)

  if statement.hasSort:
    var sortHeaderIdx = -1
    for i, h in headers:
      if h.toLowerAscii() == statement.sortCol.toLowerAscii() or ('.' in h and h.split('.')[1].toLowerAscii() == statement.sortCol.toLowerAscii()):
        sortHeaderIdx = i
        break
    if sortHeaderIdx != -1:
      joinedRows.sort(proc (a, b: seq[string]): int =
        let valA = a[sortHeaderIdx]
        let valB = b[sortHeaderIdx]
        var cmpRes = 0
        try:
          let f1 = valA.parseFloat()
          let f2 = valB.parseFloat()
          cmpRes = system.cmp(f1, f2)
        except ValueError:
          try:
            let n1 = valA.parseInt()
            let n2 = valB.parseInt()
            cmpRes = system.cmp(n1, n2)
          except ValueError:
            cmpRes = system.cmp(valA, valB)
        if statement.sortDesc:
          return -cmpRes
        else:
          return cmpRes
      )

  if statement.hasLimit and joinedRows.len > statement.limitVal:
    joinedRows = joinedRows[0 ..< statement.limitVal]

  if statement.hideWhereColumn and statement.hasWhere:
    var keepIdx: seq[int] = @[]
    var newHeaders: seq[string] = @[]
    let wColLower = statement.whereCol.toLowerAscii()
    for i, h in headers:
      let hLower = h.toLowerAscii()
      let matchesWhereCol = hLower == wColLower or ('.' in hLower and hLower.split('.')[1] == wColLower)
      if not matchesWhereCol:
        keepIdx.add(i)
        newHeaders.add(h)
    if keepIdx.len != headers.len:
      var newRows: seq[seq[string]] = @[]
      for rowVals in joinedRows:
        var newRow: seq[string] = @[]
        for i in keepIdx:
          newRow.add(rowVals[i])
        newRows.add(newRow)
      headers = newHeaders
      joinedRows = newRows

  return (headers, joinedRows)

proc executeSelectJoin(statement: Statement, db: Database, isStrip: bool = false): ExecuteResult =
  let (headers, joinedRows) = computeJoinRows(statement, db, isStrip)
  let numCols = headers.len
  var colWidths = newSeq[int](numCols)
  for i, h in headers:
    colWidths[i] = h.len

  for rowVals in joinedRows:
    for i, val in rowVals:
      if val.len > colWidths[i]:
        colWidths[i] = val.len

  var headerLine = ""
  for i, h in headers:
    let w = colWidths[i]
    headerLine.add(pad(h, w) & " | ")

  var separatorLine = ""
  for c in headerLine:
    if c == '|':
      separatorLine.add('-')
    elif c == ' ':
      separatorLine.add(' ')
    else:
      separatorLine.add('-')

  outp headerLine
  outp separatorLine

  for rowVals in joinedRows:
    var line = ""
    for i, val in rowVals:
      let w = colWidths[i]
      line.add(pad(val, w) & " | ")
    outp line

  return erSuccess

proc tokenize(line: string): seq[string] =
  var tokens: seq[string] = @[]
  var currentToken = ""
  var inQuotes = false
  var i = 0
  while i < line.len:
    let c = line[i]
    if c == '\'':
      if inQuotes:
        if i + 1 < line.len and line[i+1] == '\'':
          currentToken.add('\'')
          i.inc()
        else:
          inQuotes = false
      else:
        inQuotes = true
      i.inc()
    elif c.isSpaceAscii() and not inQuotes:
      if currentToken.len > 0:
        tokens.add(currentToken)
        currentToken = ""
      i.inc()
    else:
      currentToken.add(c)
      i.inc()
  if currentToken.len > 0:
    tokens.add(currentToken)
  return tokens

proc prepareCreateTable(parts: seq[string], statement: var Statement, db: Database): PrepareResult =
  if parts.len < 3:
    return prSyntaxError
  
  let tableName = parts[1]
  if findTableIndex(db, tableName) != -1:
    return prTableAlreadyExists

  var columns: seq[ColumnDef] = @[]
  for i in 2 ..< parts.len:
    let colParts = parts[i].split(':')
    if colParts.len != 2:
      return prSyntaxError
    let colType = colParts[1].toLowerAscii()
    if colType notin ["string", "int", "float"]:
      return prInvalidDataType
    columns.add(ColumnDef(name: colParts[0], typ: colType))

  statement.kind = stCreate
  statement.schemaToCreate = TableSchema(name: tableName, columns: columns)
  return prSuccess

proc generateUniqueId(table: Table): int =
  while true:
    let tStr = now().format("yyyyMMddHHmmss")
    let newId = tStr.parseInt()
    var exists = false
    for r in table.rows:
      if r.id == newId:
        exists = true
        break
    if not exists:
      return newId
    os.sleep(1000)

proc resolveLookupSource(db: Database, sourceName: string, sourceField: string): tuple[valid: bool, values: seq[string]] =
  let tIdx = findTableIndex(db, sourceName)
  if tIdx != -1:
    let table = db.tables[tIdx]
    let fIdx = findColumnIndex(table, sourceField)
    if fIdx == -1:
      return (false, newSeq[string]())
    var vals: seq[string] = @[]
    for row in table.rows:
      vals.add(getColumnValue(row, table, fIdx))
    return (true, vals)

  for v in db.views:
    if v.name.toLowerAscii() == sourceName.toLowerAscii():
      if v.statement.kind in {stSelectJoin, stSelectStrip}:
        let (headers, rows) = computeJoinRows(v.statement, db, v.statement.kind == stSelectStrip)
        var fieldIdx = -1
        for i, h in headers:
          if h.toLowerAscii() == sourceField.toLowerAscii() or
             ('.' in h and h.split('.')[1].toLowerAscii() == sourceField.toLowerAscii()):
            fieldIdx = i
            break
        if fieldIdx == -1:
          return (false, newSeq[string]())
        var vals: seq[string] = @[]
        for row in rows:
          vals.add(row[fieldIdx])
        return (true, vals)
      else:
        let baseIdx = findTableIndex(db, v.statement.targetTable)
        if baseIdx == -1:
          return (false, newSeq[string]())
        let baseTable = db.tables[baseIdx]
        let fIdx = findColumnIndexExtended(baseTable, v.columnAliases, sourceField)
        if fIdx == -1:
          return (false, newSeq[string]())
        var vals: seq[string] = @[]
        for row in baseTable.rows:
          if matchWhere(row, baseTable, v.statement):
            vals.add(getColumnValue(row, baseTable, fIdx))
        return (true, vals)

  return (false, newSeq[string]())

proc prepareLookup(parts: seq[string], statement: var Statement, db: Database): PrepareResult =
  if parts.len != 3 and parts.len != 4:
    return prSyntaxError

  var noDup = false
  if parts.len == 4:
    if parts[3].toUpperAscii() != "NODUP":
      return prSyntaxError
    noDup = true

  let targetSpec = parts[1].split(':')
  let sourceSpec = parts[2].split(':')
  if targetSpec.len != 2 or sourceSpec.len != 2:
    return prSyntaxError

  let targetTable = targetSpec[0].strip()
  let targetField = targetSpec[1].strip()
  let sourceTable = sourceSpec[0].strip()
  let sourceField = sourceSpec[1].strip()

  let tIdx = findTableIndex(db, targetTable)
  if tIdx == -1:
    return prTableNotFound
  if findColumnIndex(db.tables[tIdx], targetField) == -1:
    return prColumnNotFound

  let sourceCheck = resolveLookupSource(db, sourceTable, sourceField)
  if not sourceCheck.valid:
    var sourceExists = (findTableIndex(db, sourceTable) != -1)
    if not sourceExists:
      for v in db.views:
        if v.name.toLowerAscii() == sourceTable.toLowerAscii():
          sourceExists = true
          break
    if not sourceExists:
      return prTableNotFound
    return prColumnNotFound

  statement.kind = stLookup
  statement.targetTable = targetTable
  statement.lookupTargetField = targetField
  statement.lookupSourceTable = sourceTable
  statement.lookupSourceField = sourceField
  statement.lookupNoDup = noDup
  return prSuccess

proc validateLookupRules(db: Database, targetTable: string, row: Row): PrepareResult =
  let tIdx = findTableIndex(db, targetTable)
  if tIdx == -1:
    return prSuccess
  let table = db.tables[tIdx]

  for rule in db.lookups:
    if rule.targetTable.toLowerAscii() != targetTable.toLowerAscii():
      continue

    let fieldIdx = findColumnIndex(table, rule.targetField)
    if fieldIdx == -1:
      continue
    let insertVal = getColumnValue(row, table, fieldIdx)

    let source = resolveLookupSource(db, rule.sourceTable, rule.sourceField)
    if not source.valid:
      return prLookupNotFound

    var foundInSource = false
    for v in source.values:
      if v == insertVal:
        foundInSource = true
        break
    if not foundInSource:
      return prLookupNotFound

    if rule.noDup:
      for existingRow in table.rows:
        if getColumnValue(existingRow, table, fieldIdx) == insertVal:
          return prDuplicateData

  return prSuccess

proc getReferencedTableNames(rawQuery: string): seq[string] =
  result = @[]
  let toks = tokenize(rawQuery)
  for i, t in toks:
    let tl = t.toLowerAscii()
    if (tl == "select" or tl == "left" or tl == "strip") and i + 1 < toks.len:
      result.add(toks[i + 1])

proc prepareUndo(parts: seq[string], statement: var Statement, db: Database): PrepareResult =
  if parts.len != 2:
    return prSyntaxError

  let name = parts[1]

  let tIdx = findTableIndex(db, name)
  if tIdx != -1:
    if db.tables[tIdx].rows.len > 0:
      return prTableHasData
    statement.kind = stUndo
    statement.undoObjectName = name
    statement.undoKind = uokTable
    return prSuccess

  for v in db.views:
    if v.name.toLowerAscii() == name.toLowerAscii():
      for v2 in db.views:
        if v2.name.toLowerAscii() == name.toLowerAscii():
          continue
        for refName in getReferencedTableNames(v2.rawQuery):
          if refName.toLowerAscii() == name.toLowerAscii():
            return prAliasReferenced
      statement.kind = stUndo
      statement.undoObjectName = name
      statement.undoKind = uokAlias
      return prSuccess

  let spec = name.split(':')
  if spec.len == 2:
    let tgt = spec[0].strip()
    let fld = spec[1].strip()
    for lk in db.lookups:
      if lk.targetTable.toLowerAscii() == tgt.toLowerAscii() and lk.targetField.toLowerAscii() == fld.toLowerAscii():
        statement.kind = stUndo
        statement.undoObjectName = name
        statement.undoKind = uokLookup
        return prSuccess

  return prObjectNotFound

proc prepareInsert(parts: seq[string], statement: var Statement, db: Database): PrepareResult =
  if parts.len < 2:
    return prSyntaxError
  
  let tableName = parts[1]
  let tIdx = findTableIndex(db, tableName)
  if tIdx == -1:
    return prTableNotFound

  let table = db.tables[tIdx]
  let hasAutoId = table.schema.columns.len > 0 and table.schema.columns[0].name.toLowerAscii() == "id"
  let numCols = table.schema.columns.len
  let itemsAfterTable = parts.len - 2

  var id: int
  var valStartIndex: int
  var isAuto = false

  if hasAutoId and itemsAfterTable == numCols - 1:
    id = generateUniqueId(table)
    valStartIndex = 2
    isAuto = true
  elif hasAutoId and itemsAfterTable == numCols:
    try:
      id = parts[2].parseInt()
      if id < 0:
        return prNegativeId
    except ValueError:
      return prSyntaxError
    valStartIndex = 3
  elif not hasAutoId and itemsAfterTable == numCols:
    try:
      id = parts[2].parseInt()
      if id < 0:
        return prNegativeId
    except ValueError:
      return prSyntaxError
    valStartIndex = 3
  else:
    return prSyntaxError

  var values: seq[string] = @[]
  for i in valStartIndex ..< parts.len:
    values.add(parts[i])

  statement.kind = stInsert
  statement.targetTable = tableName
  statement.rowToInsert = Row(id: id, values: values)
  statement.isAutoId = isAuto

  let lookupCheck = validateLookupRules(db, tableName, statement.rowToInsert)
  if lookupCheck != prSuccess:
    return lookupCheck

  return prSuccess

proc prepareSelect(parts: seq[string], statement: var Statement, db: Database): PrepareResult =
  if parts.len < 2:
    return prSyntaxError

  let tableName = parts[1]

  var viewIdx = -1
  for i, v in db.views:
    if v.name.toLowerAscii() == tableName.toLowerAscii():
      viewIdx = i
      break

  if viewIdx != -1:
    statement = db.views[viewIdx].statement
    statement.columnAliases = db.views[viewIdx].columnAliases

    var whereIdx = -1
    for i in 2 ..< parts.len:
      if parts[i].toLowerAscii() == "where":
        whereIdx = i
        break

    var sortIdx = -1
    var isDs = false
    for i in 2 ..< parts.len:
      let tokenLower = parts[i].toLowerAscii()
      if tokenLower == "asort" or tokenLower == "dsort":
        sortIdx = i
        isDs = (tokenLower == "dsort")
        break

    var limitIdx = -1
    for i in 2 ..< parts.len:
      if parts[i].toLowerAscii() == "limit":
        limitIdx = i
        break

    var gatherIdx = -1
    for i in 2 ..< parts.len:
      if parts[i].toLowerAscii() == "gather":
        gatherIdx = i
        break

    var sumIdxPeek = -1
    for i in 2 ..< parts.len:
      let tokenLower = parts[i].toLowerAscii()
      if tokenLower == "sum" or tokenLower.startsWith("sum("):
        sumIdxPeek = i
        break

    if whereIdx != -1:
      var afterWhereClauses: seq[int] = @[]
      for cIdx in [sortIdx, limitIdx, gatherIdx, sumIdxPeek]:
        if cIdx > whereIdx: afterWhereClauses.add(cIdx)
      let whereEndIdx = if afterWhereClauses.len > 0: min(afterWhereClauses) else: parts.len
      let whereParts = parts[whereIdx + 1 ..< whereEndIdx]
      if whereParts.len == 0:
        return prSyntaxError
      
      var wCol = ""
      var wOp = ""
      var wVal = ""

      if whereParts.len == 1:
        let token = whereParts[0]
        var foundOp = ""
        for op in ["<=", ">=", "!=", "!%", "%!", "%", "=", "<", ">"]:
          if op in token:
            foundOp = op
            let opParts = token.split(op, maxsplit = 1)
            if opParts.len == 2:
              wCol = opParts[0].strip()
              wOp = foundOp
              wVal = opParts[1].strip()
            break
        if foundOp == "":
          return prSyntaxError
      elif whereParts.len >= 3:
        wCol = whereParts[0].strip()
        wOp = whereParts[1].strip()
        wVal = whereParts[2].strip()
      else:
        return prSyntaxError

      let t1 = db.tables[findTableIndex(db, statement.targetTable)]
      var colValid = (findColumnIndexExtended(t1, statement.columnAliases, wCol) != -1)
      if not colValid and statement.kind in {stSelectJoin, stSelectStrip}:
        var t2Idx = findTableIndex(db, statement.joinTable)
        var v2Idx = -1
        for i, v in db.views:
          if v.name.toLowerAscii() == statement.joinTable.toLowerAscii():
            v2Idx = i
            break
        if t2Idx != -1:
          let t2 = db.tables[t2Idx]
          if findColumnIndex(t2, wCol) != -1:
            colValid = true
        elif v2Idx != -1:
          let joinView = db.views[v2Idx]
          let t2 = db.tables[findTableIndex(db, joinView.statement.targetTable)]
          if findColumnIndexExtended(t2, joinView.columnAliases, wCol) != -1:
            colValid = true

      if not colValid:
        return prColumnNotFound

      statement.hasWhere = true
      statement.whereCol = wCol
      statement.whereOp = wOp
      statement.whereVal = wVal

    if sortIdx != -1:
      if sortIdx + 1 >= parts.len:
        return prSyntaxError
      let sCol = parts[sortIdx + 1]
      let t1 = db.tables[findTableIndex(db, statement.targetTable)]
      var colValid = (findColumnIndexExtended(t1, statement.columnAliases, sCol) != -1)
      if not colValid and statement.kind in {stSelectJoin, stSelectStrip}:
        var t2Idx = findTableIndex(db, statement.joinTable)
        var v2Idx = -1
        for i, v in db.views:
          if v.name.toLowerAscii() == statement.joinTable.toLowerAscii():
            v2Idx = i
            break
        if t2Idx != -1:
          let t2 = db.tables[t2Idx]
          if findColumnIndex(t2, sCol) != -1:
            colValid = true
        elif v2Idx != -1:
          let joinView = db.views[v2Idx]
          let t2 = db.tables[findTableIndex(db, joinView.statement.targetTable)]
          if findColumnIndexExtended(t2, joinView.columnAliases, sCol) != -1:
            colValid = true

      if not colValid:
        return prColumnNotFound

      statement.hasSort = true
      statement.sortCol = sCol
      statement.sortDesc = isDs

    if limitIdx != -1:
      if limitIdx + 1 >= parts.len:
        return prSyntaxError
      try:
        let lVal = parts[limitIdx + 1].parseInt()
        if lVal < 0:
          return prSyntaxError
        statement.hasLimit = true
        statement.limitVal = lVal
      except ValueError:
        return prSyntaxError

    if gatherIdx != -1:
      if gatherIdx + 1 >= parts.len:
        return prSyntaxError
      let gCol = parts[gatherIdx + 1]
      let t1 = db.tables[findTableIndex(db, statement.targetTable)]
      if findColumnIndexExtended(t1, statement.columnAliases, gCol) == -1:
        return prColumnNotFound
      statement.hasGather = true
      statement.gatherCol = gCol

    var sumIdx = -1
    for i in 2 ..< parts.len:
      let tokenLower = parts[i].toLowerAscii()
      if tokenLower == "sum" or tokenLower.startsWith("sum("):
        sumIdx = i
        break

    if sumIdx != -1:
      var sCol = ""
      let token = parts[sumIdx]
      if token.toLowerAscii() == "sum":
        if sumIdx + 1 >= parts.len:
          return prSyntaxError
        sCol = parts[sumIdx + 1]
      else:
        let start = token.find('(')
        let finish = token.find(')')
        if start != -1 and finish != -1 and finish > start:
          sCol = token[start + 1 .. finish - 1].strip()
        else:
          return prSyntaxError
      let t1 = db.tables[findTableIndex(db, statement.targetTable)]
      if findColumnIndexExtended(t1, statement.columnAliases, sCol) == -1:
        return prColumnNotFound
      statement.hasSum = true
      statement.sumCol = sCol

    return prSuccess

  if findTableIndex(db, tableName) == -1:
    return prTableNotFound

  var whereIdx = -1
  for i in 2 ..< parts.len:
    if parts[i].toLowerAscii() == "where":
      whereIdx = i
      break

  var sortIdx = -1
  var isDs = false
  for i in 2 ..< parts.len:
    let tokenLower = parts[i].toLowerAscii()
    if tokenLower == "asort" or tokenLower == "dsort":
      sortIdx = i
      isDs = (tokenLower == "dsort")
      break

  var limitIdx = -1
  for i in 2 ..< parts.len:
    if parts[i].toLowerAscii() == "limit":
      limitIdx = i
      break

  var gatherIdx = -1
  for i in 2 ..< parts.len:
    if parts[i].toLowerAscii() == "gather":
      gatherIdx = i
      break

  var sumIdx = -1
  for i in 2 ..< parts.len:
    let tokenLower = parts[i].toLowerAscii()
    if tokenLower == "sum" or tokenLower.startsWith("sum("):
      sumIdx = i
      break

  var clauseIndices: seq[int] = @[]
  if whereIdx != -1: clauseIndices.add(whereIdx)
  if sortIdx != -1: clauseIndices.add(sortIdx)
  if limitIdx != -1: clauseIndices.add(limitIdx)
  if gatherIdx != -1: clauseIndices.add(gatherIdx)
  if sumIdx != -1: clauseIndices.add(sumIdx)

  let selectEndIdx = if clauseIndices.len > 0: min(clauseIndices) else: parts.len
  let selectParts = parts[0 ..< selectEndIdx]

  if selectParts.len == 2:
    statement.kind = stSelect
    statement.targetTable = tableName
  else:
    var idx = 2
    let kw = selectParts[idx].toLowerAscii()
    if kw == "left" or kw == "strip":
      let isStrip = (kw == "strip")
      idx.inc()
      
      if idx >= selectParts.len:
        return prSyntaxError
      
      let joinTable = selectParts[idx]
      var t2Idx = findTableIndex(db, joinTable)
      var v2Idx = -1
      for i, v in db.views:
        if v.name.toLowerAscii() == joinTable.toLowerAscii():
          v2Idx = i
          break

      if t2Idx == -1 and v2Idx == -1:
        return prTableNotFound
      
      idx.inc()
      if idx < selectParts.len and selectParts[idx].toLowerAscii() == "on":
        idx.inc()

      if idx >= selectParts.len:
        return prSyntaxError

      var col1 = ""
      var col2 = ""
      let token = selectParts[idx]
      
      if '=' in token:
        let eqParts = token.split('=')
        if eqParts.len == 2:
          col1 = eqParts[0].strip()
          col2 = eqParts[1].strip()
        else:
          return prSyntaxError
      elif idx + 2 < selectParts.len and selectParts[idx+1] == "=":
        col1 = selectParts[idx]
        col2 = selectParts[idx+2]
      elif idx + 1 < selectParts.len:
        col1 = selectParts[idx]
        col2 = selectParts[idx+1]
      else:
        return prSyntaxError

      let t1 = db.tables[findTableIndex(db, tableName)]
      var t2: Table
      var t2Aliases: seq[tuple[orig: string, alias: string]] = @[]

      if t2Idx != -1:
        t2 = db.tables[t2Idx]
      else:
        let joinView = db.views[v2Idx]
        t2 = db.tables[findTableIndex(db, joinView.statement.targetTable)]
        t2Aliases = joinView.columnAliases

      if findColumnIndexExtended(t1, statement.columnAliases, col1) == -1 or findColumnIndexExtended(t2, t2Aliases, col2) == -1:
        return prColumnNotFound

      statement.kind = if isStrip: stSelectStrip else: stSelectJoin
      statement.targetTable = tableName
      statement.joinTable = joinTable
      statement.joinCol1 = col1
      statement.joinCol2 = col2
    else:
      return prSyntaxError

  if whereIdx != -1:
    var afterWhereClauses: seq[int] = @[]
    for cIdx in [sortIdx, limitIdx, gatherIdx, sumIdx]:
      if cIdx > whereIdx: afterWhereClauses.add(cIdx)
    let whereEndIdx = if afterWhereClauses.len > 0: min(afterWhereClauses) else: parts.len
    let whereParts = parts[whereIdx + 1 ..< whereEndIdx]
    if whereParts.len == 0:
      return prSyntaxError
    
    var wCol = ""
    var wOp = ""
    var wVal = ""

    if whereParts.len == 1:
      let token = whereParts[0]
      var foundOp = ""
      for op in ["<=", ">=", "!=", "!%", "%!", "%", "=", "<", ">"]:
        if op in token:
          foundOp = op
          let opParts = token.split(op, maxsplit = 1)
          if opParts.len == 2:
            wCol = opParts[0].strip()
            wOp = foundOp
            wVal = opParts[1].strip()
          break
      if foundOp == "":
        return prSyntaxError
    elif whereParts.len >= 3:
      wCol = whereParts[0].strip()
      wOp = whereParts[1].strip()
      wVal = whereParts[2].strip()
    else:
      return prSyntaxError

    let t1 = db.tables[findTableIndex(db, statement.targetTable)]
    var colValid = (findColumnIndexExtended(t1, statement.columnAliases, wCol) != -1)
    if not colValid and statement.kind in {stSelectJoin, stSelectStrip}:
      var t2Idx = findTableIndex(db, statement.joinTable)
      var v2Idx = -1
      for i, v in db.views:
        if v.name.toLowerAscii() == statement.joinTable.toLowerAscii():
          v2Idx = i
          break
      if t2Idx != -1:
        let t2 = db.tables[t2Idx]
        if findColumnIndex(t2, wCol) != -1:
          colValid = true
      elif v2Idx != -1:
        let joinView = db.views[v2Idx]
        let t2 = db.tables[findTableIndex(db, joinView.statement.targetTable)]
        if findColumnIndexExtended(t2, joinView.columnAliases, wCol) != -1:
          colValid = true

    if not colValid:
      return prColumnNotFound

    statement.hasWhere = true
    statement.whereCol = wCol
    statement.whereOp = wOp
    statement.whereVal = wVal

  if sortIdx != -1:
    if sortIdx + 1 >= parts.len:
      return prSyntaxError
    let sCol = parts[sortIdx + 1]
    let t1 = db.tables[findTableIndex(db, statement.targetTable)]
    var colValid = (findColumnIndexExtended(t1, statement.columnAliases, sCol) != -1)
    if not colValid and statement.kind in {stSelectJoin, stSelectStrip}:
      var t2Idx = findTableIndex(db, statement.joinTable)
      var v2Idx = -1
      for i, v in db.views:
        if v.name.toLowerAscii() == statement.joinTable.toLowerAscii():
          v2Idx = i
          break
      if t2Idx != -1:
        let t2 = db.tables[t2Idx]
        if findColumnIndex(t2, sCol) != -1:
          colValid = true
      elif v2Idx != -1:
        let joinView = db.views[v2Idx]
        let t2 = db.tables[findTableIndex(db, joinView.statement.targetTable)]
        if findColumnIndexExtended(t2, joinView.columnAliases, sCol) != -1:
          colValid = true

    if not colValid:
      return prColumnNotFound

    statement.hasSort = true
    statement.sortCol = sCol
    statement.sortDesc = isDs

  if limitIdx != -1:
    if limitIdx + 1 >= parts.len:
      return prSyntaxError
    try:
      let lVal = parts[limitIdx + 1].parseInt()
      if lVal < 0:
        return prSyntaxError
      statement.hasLimit = true
      statement.limitVal = lVal
    except ValueError:
      return prSyntaxError

  if gatherIdx != -1:
    if gatherIdx + 1 >= parts.len:
      return prSyntaxError
    let gCol = parts[gatherIdx + 1]
    let t1 = db.tables[findTableIndex(db, statement.targetTable)]
    if findColumnIndexExtended(t1, statement.columnAliases, gCol) == -1:
      return prColumnNotFound
    statement.hasGather = true
    statement.gatherCol = gCol

  if sumIdx != -1:
    var sCol = ""
    let token = parts[sumIdx]
    if token.toLowerAscii() == "sum":
      if sumIdx + 1 >= parts.len:
        return prSyntaxError
      sCol = parts[sumIdx + 1]
    else:
      let start = token.find('(')
      let finish = token.find(')')
      if start != -1 and finish != -1 and finish > start:
        sCol = token[start + 1 .. finish - 1].strip()
      else:
        return prSyntaxError
    let t1 = db.tables[findTableIndex(db, statement.targetTable)]
    if findColumnIndexExtended(t1, statement.columnAliases, sCol) == -1:
      return prColumnNotFound
    statement.hasSum = true
    statement.sumCol = sCol

  return prSuccess

proc prepareAlias(parts: seq[string], statement: var Statement, db: Database): PrepareResult =
  if parts.len < 4:
    return prSyntaxError

  let aliasName = parts[1]
  if findTableIndex(db, aliasName) != -1:
    return prTableAlreadyExists
  for v in db.views:
    if v.name.toLowerAscii() == aliasName.toLowerAscii():
      return prTableAlreadyExists

  var selectIdx = -1
  for i in 2 ..< parts.len:
    if parts[i].toLowerAscii() == "select":
      selectIdx = i
      break

  if selectIdx == -1 or selectIdx <= 2:
    return prSyntaxError

  var colAliases: seq[tuple[orig: string, alias: string]] = @[]
  var computedCols: seq[ComputedColumn] = @[]
  for i in 2 ..< selectIdx:
    let lastColon = parts[i].rfind(':')
    if lastColon == -1:
      return prSyntaxError
    let leftPart = parts[i][0 ..< lastColon].strip()
    let aliasPart = parts[i][lastColon + 1 .. ^1].strip()
    if aliasPart.len == 0:
      return prSyntaxError

    if leftPart.startsWith("(") and leftPart.endsWith(")"):
      let node = parseExpression(leftPart)
      computedCols.add((expr: node, alias: aliasPart))
    else:
      let mapping = parts[i].split(':')
      if mapping.len != 2:
        return prSyntaxError
      colAliases.add((orig: mapping[0].strip(), alias: mapping[1].strip()))

  var subQueryParts = parts[selectIdx .. ^1]
  var subStmt: Statement
  let res = prepareSelect(subQueryParts, subStmt, db)
  if res != prSuccess:
    return res

  subStmt.columnAliases = colAliases
  subStmt.computedCols = computedCols

  statement.kind = stAlias
  statement.aliasName = aliasName
  statement.columnAliases = colAliases
  statement.computedCols = computedCols
  statement.subStatement = new Statement
  statement.subStatement[] = subStmt
  return prSuccess

proc prepareStatement(line: string, statement: var Statement, db: Database): PrepareResult =
  let fullParts = tokenize(line)
  if fullParts.len == 0:
    return prUnrecognizedStatement

  let cmd = fullParts[0].toLowerAscii()
  if cmd == "create":
    return prepareCreateTable(fullParts, statement, db)
  elif cmd == "insert":
    return prepareInsert(fullParts, statement, db)
  elif cmd == "select":
    return prepareSelect(fullParts, statement, db)
  elif cmd == "alias":
    return prepareAlias(fullParts, statement, db)
  elif cmd == "object":
    if fullParts.len != 1 and fullParts.len != 2:
      return prSyntaxError
    statement.kind = stObject
    if fullParts.len == 2:
      statement.objectTarget = fullParts[1]
    return prSuccess
  elif cmd == "lookup":
    return prepareLookup(fullParts, statement, db)
  elif cmd == "undo":
    return prepareUndo(fullParts, statement, db)
  else:
    return prUnrecognizedStatement

proc executeCreate(statement: Statement, db: var Database, rawLine: string = ""): ExecuteResult =
  let newTable = Table(schema: statement.schemaToCreate, rawCreateLine: rawLine, rows: @[])
  db.tables.add(newTable)
  return erSuccess

proc executeInsert(statement: Statement, db: var Database): ExecuteResult =
  let idx = findTableIndex(db, statement.targetTable)
  if idx != -1:
    db.tables[idx].rows.add(statement.rowToInsert)
  return erSuccess

proc executeSelect(statement: Statement, db: Database): ExecuteResult =
  let idx = findTableIndex(db, statement.targetTable)
  if idx != -1:
    printTableFiltered(db.tables[idx], statement)
  return erSuccess

proc executeStatement(statement: Statement, db: var Database, rawLine: string = ""): ExecuteResult

proc executeAlias(statement: Statement, db: var Database, rawLine: string = ""): ExecuteResult =
  let view = AliasView(name: statement.aliasName, rawQuery: rawLine, columnAliases: statement.columnAliases, statement: statement.subStatement[])
  db.views.add(view)
  return erSuccess

proc executeLookup(statement: Statement, db: var Database, rawLine: string = ""): ExecuteResult =
  let rule = LookupRule(
    targetTable: statement.targetTable,
    targetField: statement.lookupTargetField,
    sourceTable: statement.lookupSourceTable,
    sourceField: statement.lookupSourceField,
    noDup: statement.lookupNoDup,
    rawLine: rawLine
  )
  db.lookups.add(rule)
  return erSuccess

proc executeUndo(statement: Statement, db: var Database): ExecuteResult =
  let name = statement.undoObjectName
  case statement.undoKind
  of uokTable:
    var newTables: seq[Table] = @[]
    for t in db.tables:
      if t.schema.name.toLowerAscii() != name.toLowerAscii():
        newTables.add(t)
    db.tables = newTables
  of uokAlias:
    var newViews: seq[AliasView] = @[]
    for v in db.views:
      if v.name.toLowerAscii() != name.toLowerAscii():
        newViews.add(v)
    db.views = newViews
  of uokLookup:
    let spec = name.split(':')
    let tgt = spec[0].strip()
    let fld = spec[1].strip()
    var newLookups: seq[LookupRule] = @[]
    var removed = false
    for lk in db.lookups:
      if not removed and lk.targetTable.toLowerAscii() == tgt.toLowerAscii() and
         lk.targetField.toLowerAscii() == fld.toLowerAscii():
        removed = true
        continue
      newLookups.add(lk)
    db.lookups = newLookups
  return erSuccess

proc executeObject(statement: Statement, db: Database) =
  if statement.objectTarget.len > 0:
    let target = statement.objectTarget
    let tIdx = findTableIndex(db, target)
    if tIdx != -1:
      outp "Type: Table"
      outp "Definition: ", db.tables[tIdx].rawCreateLine
      return

    for v in db.views:
      if v.name.toLowerAscii() == target.toLowerAscii():
        outp "Type: Alias"
        outp "Definition: ", v.rawQuery
        return

    outp "Error: Object '", target, "' not found."
    return

  outp "--- TABLES ---"
  if db.tables.len == 0:
    outp "(No tables)"
  else:
    var names: seq[string] = @[]
    for t in db.tables:
      names.add(t.schema.name)
    outp names.join("  ")

  outp "--- ALIASES ---"
  if db.views.len == 0:
    outp "(No aliases)"
  else:
    var names: seq[string] = @[]
    for v in db.views:
      names.add(v.name)
    outp names.join("  ")

  outp "--- LOOKUPS ---"
  if db.lookups.len == 0:
    outp "(No lookups)"
  else:
    for lk in db.lookups:
      var line = " - " & lk.targetTable & ":" & lk.targetField & " -> " & lk.sourceTable & ":" & lk.sourceField
      if lk.noDup:
        line.add(" NODUP")
      outp line

proc executeStatement(statement: Statement, db: var Database, rawLine: string = ""): ExecuteResult =
  case statement.kind
  of stCreate:
    return executeCreate(statement, db, rawLine)
  of stInsert:
    return executeInsert(statement, db)
  of stSelect:
    return executeSelect(statement, db)
  of stSelectJoin:
    return executeSelectJoin(statement, db, false)
  of stSelectStrip:
    return executeSelectJoin(statement, db, true)
  of stAlias:
    return executeAlias(statement, db, rawLine)
  of stLookup:
    return executeLookup(statement, db, rawLine)
  of stUndo:
    return executeUndo(statement, db)
  of stObject:
    executeObject(statement, db)
    return erSuccess

proc logCommand(line: string) =
  try:
    let f = open(LogFileName, fmAppend)
    f.writeLine(line)
    f.close()
  except IOError:
    outp "Error: Failed to write to log file."

proc loadAndReplayLog(db: var Database) =
  if not fileExists(LogFileName):
    return

  outp "Restoring database from ", LogFileName, "..."
  for line in lines(LogFileName):
    let trimmed = line.strip()
    if trimmed.len == 0:
      continue
    
    var statement: Statement
    if prepareStatement(trimmed, statement, db) == prSuccess:
      if statement.kind == stAlias:
        let view = AliasView(name: statement.aliasName, rawQuery: trimmed, columnAliases: statement.columnAliases, statement: statement.subStatement[])
        db.views.add(view)
      elif statement.kind == stCreate:
        discard executeStatement(statement, db, trimmed)
      else:
        discard executeStatement(statement, db, trimmed)
  outp "Recovery complete.\n"

proc isNotNumeric(s: string): bool =
  try:
    discard s.parseFloat()
    result = false
  except ValueError:
    result = true

proc splitTopLevelAmpersand(line: string): seq[string] =
  result = @[]
  var current = ""
  var insideQuote = false
  for c in line:
    if c == '\'':
      insideQuote = not insideQuote
      current.add(c)
    elif c == '&' and not insideQuote:
      result.add(current)
      current = ""
    else:
      current.add(c)
  result.add(current)

proc runOneCommand(line: string, db: var Database, isChained: bool) =
  var statement: Statement
  let fullParts = tokenize(line)
  case prepareStatement(line, statement, db)
  of prSuccess:
    if isChained and statement.kind in {stSelect, stSelectJoin, stSelectStrip} and
       statement.hasWhere and statement.whereOp == "=":
      statement.hideWhereColumn = true

    let res = executeStatement(statement, db, line)
    if res == erSuccess:
      if statement.kind in {stCreate, stInsert, stAlias, stLookup, stUndo}:
        var logLine = line
        if statement.kind == stInsert:
          let tIdx = findTableIndex(db, statement.targetTable)
          if tIdx != -1:
            let table = db.tables[tIdx]
            let hasAutoId = table.schema.columns.len > 0 and table.schema.columns[0].name.toLowerAscii() == "id"
            if hasAutoId and fullParts.len == table.schema.columns.len + 1:
              logLine = "insert " & statement.targetTable & " " & $statement.rowToInsert.id
              for k, val in statement.rowToInsert.values:
                let colIdx = k + 1
                var formattedVal = val
                if colIdx < table.schema.columns.len:
                  let colType = table.schema.columns[colIdx].typ.toLowerAscii()
                  if colType == "string" or ' ' in val or isNotNumeric(val):
                    if not (val.startsWith("'") and val.endsWith("'")):
                      formattedVal = "'" & val & "'"
                logLine.add(" " & formattedVal)
        logCommand(logLine)

      if not isChained:
        if statement.kind == stInsert and statement.isAutoId:
          outp "Executed. ID = ", statement.rowToInsert.id
        elif statement.kind notin {stObject, stSelect, stSelectJoin, stSelectStrip}:
          outp "Executed."
  of prSyntaxError:
    outp "Syntax error in statement."
  of prNegativeId:
    outp "ID must be a positive integer."
  of prTableNotFound:
    outp "Error: Table does not exist."
  of prTableAlreadyExists:
    outp "Error: Table already exists."
  of prColumnNotFound:
    outp "Error: Column specified does not exist."
  of prInvalidDataType:
    outp "Error: Invalid data type specified. Use string, int, or float."
  of prLookupNotFound:
    outp "Error: Data not found in the reference table (LOOKUP failed)."
  of prDuplicateData:
    outp "Error: Duplicate data is not allowed (NODUP)."
  of prObjectNotFound:
    outp "Error: Object not found."
  of prTableHasData:
    outp "Error: Table still contains data, UNDO cancelled."
  of prAliasReferenced:
    outp "Error: Alias is still referenced by another alias, UNDO cancelled."
  of prUnrecognizedStatement:
    outp "Unrecognized statement: ", line

proc processLine(line: string, db: var Database): string =
  captureOutput = true
  outputBuffer = ""

  let subCommands = splitTopLevelAmpersand(line)
  if subCommands.len > 1:
    for subCmd in subCommands:
      let trimmed = subCmd.strip()
      if trimmed.len == 0:
        continue
      runOneCommand(trimmed, db, true)
  else:
    runOneCommand(line, db, false)

  captureOutput = false
  result = outputBuffer

proc main() =
  requireSingleInstance()
  var db = Database(tables: @[], views: @[], lookups: @[])
  
  loadAndReplayLog(db)

  while true:
    stdout.write("sinear > ")
    flushFile(stdout)
    
    let line = stdin.readLine().strip()
    if line.len == 0:
      continue

    if line.toLowerAscii() == "exit":
      outp "Exiting database..."
      quit(0)

    let outputText = processLine(line, db)
    stdout.write(outputText)
    flushFile(stdout)


const IndexHtml = """
<!DOCTYPE html>
<html lang="id">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>sinear Console</title>
<style>
  :root {
    --bg: #0f1115;
    --panel: #161a21;
    --border: #262b34;
    --text: #e6e8eb;
    --muted: #8a919e;
    --accent: #4f8cff;
    --ok: #3ecf8e;
    --err: #ff6b6b;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    background: var(--bg);
    color: var(--text);
    font-family: 'Segoe UI', system-ui, -apple-system, sans-serif;
    height: 100vh;
    display: flex;
    flex-direction: column;
  }
  header {
    padding: 14px 20px;
    border-bottom: 1px solid var(--border);
    display: flex;
    align-items: center;
    gap: 10px;
  }
  header h1 {
    font-size: 16px;
    margin: 0;
    font-weight: 600;
  }
  header span {
    color: var(--muted);
    font-size: 12px;
  }
  #log {
    flex: 1;
    overflow-y: auto;
    padding: 16px 20px;
    font-family: 'Cascadia Code', 'Consolas', monospace;
    font-size: 13px;
  }
  .entry { margin-bottom: 18px; }
  .cmd {
    color: var(--accent);
    font-weight: 600;
    margin-bottom: 4px;
  }
  .cmd::before { content: "» "; color: var(--muted); }
  .out {
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 10px 12px;
    white-space: pre-wrap;
    word-break: break-word;
    color: var(--text);
  }
  .out.error { color: var(--err); }
  .out.empty { color: var(--muted); font-style: italic; }
  form {
    display: flex;
    gap: 10px;
    padding: 14px 20px;
    border-top: 1px solid var(--border);
    background: var(--panel);
  }
  input[type=text] {
    flex: 1;
    background: #0f1115;
    border: 1px solid var(--border);
    color: var(--text);
    padding: 10px 12px;
    border-radius: 6px;
    font-family: 'Cascadia Code', 'Consolas', monospace;
    font-size: 13px;
    outline: none;
  }
  input[type=text]:focus { border-color: var(--accent); }
  button {
    background: var(--accent);
    color: white;
    border: none;
    padding: 0 20px;
    border-radius: 6px;
    cursor: pointer;
    font-size: 13px;
    font-weight: 600;
  }
  button:hover { opacity: 0.9; }
  button:disabled { opacity: 0.5; cursor: default; }
  #hint {
    padding: 6px 20px;
    color: var(--muted);
    font-size: 11px;
    border-top: 1px solid var(--border);
  }
</style>
</head>
<body>
  <header>
    <h1>sinear</h1>
    <span>console via HTTP (--server mode)</span>
  </header>

  <div id="log"></div>

  <div id="hint">Example: <code>create t id:int name:string</code> &middot; <code>select t asort id & select t limit 1</code> &middot; use ↑/↓ for history</div>
  <form id="cmdForm" autocomplete="off">
    <input type="text" id="cmdInput" placeholder="Type a command, e.g.: select ..." autofocus>
    <button type="submit" id="runBtn">Run</button>
  </form>

<script>
const log = document.getElementById('log');
const form = document.getElementById('cmdForm');
const input = document.getElementById('cmdInput');
const runBtn = document.getElementById('runBtn');

let history = [];
let historyPos = -1;

function addEntry(cmd, outputText, isError) {
  const entry = document.createElement('div');
  entry.className = 'entry';

  const cmdEl = document.createElement('div');
  cmdEl.className = 'cmd';
  cmdEl.textContent = cmd;
  entry.appendChild(cmdEl);

  const outEl = document.createElement('div');
  outEl.className = 'out' + (isError ? ' error' : '') + (outputText.trim().length === 0 ? ' empty' : '');
  outEl.textContent = outputText.trim().length === 0 ? '(no output)' : outputText;
  entry.appendChild(outEl);

  log.appendChild(entry);
  log.scrollTop = log.scrollHeight;
}

async function runCommand(cmd) {
  runBtn.disabled = true;
  try {
    const res = await fetch('/api/command', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ command: cmd })
    });
    const data = await res.json();
    if (data.error) {
      addEntry(cmd, data.error, true);
    } else {
      addEntry(cmd, data.output || '', false);
    }
  } catch (err) {
    addEntry(cmd, 'Failed to reach server: ' + err, true);
  } finally {
    runBtn.disabled = false;
  }
}

form.addEventListener('submit', function (e) {
  e.preventDefault();
  const cmd = input.value.trim();
  if (!cmd) return;
  history.push(cmd);
  historyPos = history.length;
  input.value = '';
  runCommand(cmd);
});

input.addEventListener('keydown', function (e) {
  if (e.key === 'ArrowUp') {
    if (historyPos > 0) {
      historyPos--;
      input.value = history[historyPos];
    }
    e.preventDefault();
  } else if (e.key === 'ArrowDown') {
    if (historyPos < history.length - 1) {
      historyPos++;
      input.value = history[historyPos];
    } else {
      historyPos = history.length;
      input.value = '';
    }
    e.preventDefault();
  }
});
</script>
</body>
</html>
"""

proc runServer(port: int) =
  requireSingleInstance()
  var db = Database(tables: @[], views: @[], lookups: @[])
  loadAndReplayLog(db)

  var server = newAsyncHttpServer()

  proc cb(req: Request) {.async, gcsafe.} =
    {.cast(gcsafe).}:
      let path = req.url.path
      let corsHeaders = @[
        ("Access-Control-Allow-Origin", "*"),
        ("Access-Control-Allow-Methods", "GET, POST, OPTIONS"),
        ("Access-Control-Allow-Headers", "Content-Type")
      ]

      if req.reqMethod == HttpOptions:
        await req.respond(Http204, "", newHttpHeaders(corsHeaders))

      elif req.reqMethod == HttpGet and (path == "/" or path == "/index.html"):
        await req.respond(Http200, IndexHtml, newHttpHeaders(corsHeaders & @[("Content-Type", "text/html; charset=utf-8")]))

      elif req.reqMethod == HttpPost and (path == "/api/command" or path == "/"):
        var cmdText = ""
        var parseErr = false
        try:
          let body = parseJson(req.body)
          cmdText = body["command"].getStr("")
        except:
          cmdText = req.body.strip()
          if cmdText.len == 0:
            parseErr = true

        let headers = newHttpHeaders(corsHeaders & @[("Content-Type", "application/json; charset=utf-8")])
        if parseErr or cmdText.strip().len == 0:
          let errJson = %*{"error": "Empty command or invalid request body."}
          await req.respond(Http400, $errJson, headers)
        else:
          try:
            let outputText = processLine(cmdText, db)
            let resJson = %*{"command": cmdText, "output": outputText}
            await req.respond(Http200, $resJson, headers)
          except Exception as e:
            captureOutput = false
            let errJson = %*{"command": cmdText, "error": "Internal error: " & e.msg}
            await req.respond(Http500, $errJson, headers)

      else:
        await req.respond(Http404, "Not Found", newHttpHeaders(corsHeaders & @[("Content-Type", "text/plain")]))

  echo "sinear is running as an HTTP server at http://localhost:", port, "  (Ctrl+C to stop)"
  waitFor server.serve(Port(port), cb)


const DefaultCrudHtmlFile = "crud.html"

proc runCrudServer(port: int, htmlFile: string) =
  if not fileExists(htmlFile):
    echo "Error: CRUD interface file '", htmlFile, "' not found."
    echo "Make sure the file exists in the working directory, or specify a different file via --crud=<filename.html>."
    quit(1)

  var server = newAsyncHttpServer()

  proc cb(req: Request) {.async, gcsafe.} =
    {.cast(gcsafe).}:
      let path = req.url.path
      if req.reqMethod == HttpGet and (path == "/" or path == "/index.html"):
        try:
          let htmlContent = readFile(htmlFile)
          await req.respond(Http200, htmlContent, newHttpHeaders([("Content-Type", "text/html; charset=utf-8")]))
        except IOError:
          await req.respond(Http500, "Gagal membaca file " & htmlFile, newHttpHeaders([("Content-Type", "text/plain")]))
      else:
        await req.respond(Http404, "Not Found", newHttpHeaders([("Content-Type", "text/plain")]))

  echo "sinear CRUD server is running at http://localhost:", port, "  (Ctrl+C to stop)"
  echo "Serving interface from file: ", htmlFile
  echo "Make sure the database server (sinear --server) is already running on a different port."
  waitFor server.serve(Port(port), cb)

when isMainModule:
  let cliArgs = commandLineParams()
  var serverMode = false
  var crudMode = false
  var crudHtmlFile = DefaultCrudHtmlFile
  var portOverride = -1

  for i, a in cliArgs:
    if a == "--server":
      serverMode = true
    elif a == "--crud":
      crudMode = true
    elif a.startsWith("--crud="):
      crudMode = true
      let val = a[7 .. ^1].strip()
      if val.len > 0:
        crudHtmlFile = val
    elif a.startsWith("--port="):
      try:
        portOverride = a[7 .. ^1].parseInt()
      except ValueError:
        discard

  if crudMode:
    runCrudServer(port = (if portOverride != -1: portOverride else: 8081), htmlFile = crudHtmlFile)
  elif serverMode:
    runServer(if portOverride != -1: portOverride else: 8080)
  else:
    main()
