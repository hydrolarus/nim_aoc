# This is just an example to get you started. A typical library package
# exports the main API in this file. Note that you cannot rename this file
# but you can remove it if you wish.

import macros
import os
import strutils
import tables
import strformat
import options
import std/rdstdin

import times
import std/monotimes

import std/net
import httpclient

type
    DayPart = object
        name: string
        parser: string
        solver: string

    DayModuleData = object
        day: uint
        name: NimNode
        parts: seq[DayPart]
        loneParsers: seq[string]

proc processModule(name: NimNode, dayNum: uint): DayModuleData =
    ## Pull data out of the module such as solvers and parsers
    
    let lineInfo = name.lineInfoObj
    let modulePath = lineInfo.filename.parentDir / &"{name.strVal}.nim"

    let module = readFile(modulePath).parseStmt()

    var pubProcs: seq[string] = @[]
    for child in module:
        if child.kind != nnkProcDef:
            continue

        if child[0].kind != nnkPostfix:
            continue
            
        if child[0][0].strVal != "*":
            continue

        pubProcs.add(child[0][1].strVal)

    var parsers: seq[tuple[stripped: string, full: string]]
    var solvers: seq[tuple[stripped: string, full: string]]

    for name in pubProcs:
        var stripped = name
        if name.startsWith("solve"):
            stripped.removePrefix("solve")
            solvers.add((stripped, name))
        if name.startsWith("parse"):
            stripped.removePrefix("parse")
            parsers.add((stripped, name))

    var parts: seq[DayPart]

    for solver in solvers:
        let partName = solver[0]
        var parser: string

        for p in parsers:
            if partName.startsWith(p.stripped) or p.stripped == "":
                if parser.len < p.full.len:
                    parser = p.full
        
        if parser == "":
            let message = "No parser for solver \"" & solver[1] & "\" defined. " &
                "Define an exported proc named `parser` or `parser" & partName & "`."
            error(message, name)
        
        var part = DayPart(name: partName, parser: parser, solver: solver[1])
        parts.add(part)
    
    result.loneParsers = @[]

    for parser in parsers:
        var foundAny = false
        for part in parts:
            if part.parser == parser.full:
                foundAny = true
        if not foundAny:
            result.loneParsers.add(parser.full)
    
    result.parts = parts
    result.day = dayNum
    result.name = name
    


proc measureRuntime*[T, R](input: T, p: proc(input: T): R): tuple[result: R, time: Duration] =
    let startTime: MonoTime = getMonoTime()
    let res = p(input)
    let endTime: MonoTime = getMonoTime()
    let duration: Duration = endTime - startTime
    (result: res, time: duration)

# Nicer duration output than what `$` outputs
proc formatDuration*(d: Duration): string =
    var numParts = toParts(d)

    var firstUnit: TimeUnit

    for unit in countdown(Weeks, Nanoseconds):
        let quantity = numParts[unit]
        if quantity != 0.int64:
            firstUnit = unit
            break
    
    proc formatNum(x: float64, unit: string): string =
        &"{x} {unit}"

    case firstUnit
    of Nanoseconds:
        result = $d.inNanoseconds() & " ns"
    of Microseconds:
        result = formatNum(d.inNanoseconds.float64 / 1000.0, "μs")
    of Milliseconds:
        result = formatNum(d.inMicroseconds.float64 / 1000.0, "ms")
    of Seconds:
        result = formatNum(d.inMilliseconds.float64 / 1000.0, "s")
    of Minutes:
        result = formatNum(d.inSeconds.float64 / 60.0, "min")
    else:
        result = $d



proc genCodeForPart(dayNum: uint, module: NimNode, part: DayPart): NimNode =
    let inputName = newIdentNode("input")
    let dayNum = newLit(dayNum)
    let partName = newLit(part.name)

    let parser = newDotExpr(module, newIdentNode(part.parser))
    let solver = newDotExpr(module, newIdentNode(part.solver))

    result = quote do:
        let parseRes = measureRuntime(`inputName`, `parser`)
        let solverRes = measureRuntime(parseRes.result, `solver`)
        echo "Day ", `dayNum`, " - ", `partName`, " = ", solverRes.result
        echo "    Parser: ", parseRes.time.formatDuration()
        echo "    Solver: ", solverRes.time.formatDuration()
        echo ""

proc genCodeForDays(days: openArray[DayModuleData]): NimNode =
    let inputName = newIdentNode("input")
    let dayName = newIdentNode("days")

    var dayCode = newStmtList()
    dayCode.add quote do:
        var `dayName`: OrderedTable[uint, proc(`inputName`: string) {.nimcall.}]

    for day in days:
        let dayNum = newLit(day.day)
        
        var parts = newStmtList()
        for part in day.parts:
            parts.add genCodeForPart(day.day, day.name, part)
        
        for parser in day.loneParsers:
            let parserProc = newDotExpr(day.name, newIdentNode(parser))
            let parserName = newLit(parser)
            parts.add quote do:
                let parseRes = measureRuntime(`inputName`, `parserProc`)
                echo "Day ", `dayNum`, " - ", `parserName`, " : ", parseRes.time.formatDuration()
                echo "    Output: ", parseRes.result
                echo ""

        
        dayCode.add quote do:
            `dayName`[`dayNum`] = (proc(`inputName`: string) =
                    `parts`
                )
        

    # run(input)
    #
    # run(input) = day.parts.each(it(input)); day.loneParsers.each(it(input))
    # day = object parts: seq[proc(string)], loneParsers: seq[proc(string)]

    result = quote do:

        proc runDay(day: uint, input: string) =
            `dayCode`

            # TODO error checking
            (`dayName`[day])(input)



proc getDayNumber*(max: uint): uint =
    let params = commandLineParams()
    if params.len() == 0:
        result = max
    else:
        result = parseUInt(params[0])


proc downloadInput(year: int, day: uint, sessionKey: string): string =
    let client = newHttpClient(sslContext=newContext())
    client.headers = newHttpHeaders({"COOKIE": "session="&sessionKey})
    let url = &"https://adventofcode.com/{year}/day/{day}/input"
    return client.getContent(url)


proc getOrSetSession(): Option[string] =
    let dirPath = getConfigDir() / "nim-aoc"
    createDir(dirPath)

    let path = dirPath / "credentials"
    if fileExists(path):
        let session = readFile(path).strip()
        if session == "":
            return none[string]()
        return some(session)
    
    let session = readLineFromStdin("Enter AoC session key (empty to ignore): ")

    if session == "":
        writeFile(path, "")
        return none[string]()

    writeFile(path, session.strip())
    return some(session.strip())


proc getInput*(inputDir: string, year: int, day: uint): string =
    let fileName = inputDir / &"day{day}.txt"

    if not dirExists(inputDir):
        createDir(inputDir)

    if fileExists(fileName):
        return readFile(fileName)
    
    let session = getOrSetSession()

    if session.isSome():
        let input = downloadInput(year, day, session.get())
        writeFile(fileName, input)
        return input
    else:
        writeFile(fileName, "")
        echo "Input could not be downloaded, please paste the input from the AoC wesite into ", fileName
        return ""

    


macro aoc*(year: static[int], inputDir: static[string], body: untyped): untyped =
    var days: seq[DayModuleData] = @[]

    var maxDayNum = 0'u

    for child in body:
        child.expectKind nnkIdent
        var day = child.strVal
        day.removePrefix("day")

        let dayNum = parseUInt(day)
        maxDayNum = max(dayNum, maxDayNum)

        days.add processModule(child, dayNum)

    let dayCode = genCodeForDays(days)

    let yearLit = newLit(year)
    let maxDayLit = newLit(maxDayNum)
    let inputDirLit = newLit(inputDir)

    quote do:
        when isMainModule:
            echo "============="
            echo "AoC Year ", `yearLit`
            echo "============="
            echo ""

            let day = getDayNumber(`maxDayLit`)

            `dayCode`

            let input = getInput(`inputDirLit`, `yearLit`, day)
            runDay(day, input)