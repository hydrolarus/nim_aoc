import strutils

proc parse*(input: string): seq[uint] =
    for line in input.splitLines():
        if line == "": continue

        result.add parseUInt(line)

proc solvePart1*(input: seq[uint]): uint =
    let len = input.len()
    for i in 0..<len:
        for j in i..<len:
            if input[i] + input[j] == 2020:
                return input[i] * input[j]

proc solvePart2*(input: seq[uint]): uint =
    let len = input.len()
    for i in 0..<len:
        for j in i..<len:
            for k in j..<len:
                if input[i] + input[j] + input[k] == 2020:
                    return input[i] * input[j] * input[k]