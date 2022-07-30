import std/[httpclient, json, strformat, strutils, pegs, tables, os]
import ../test/jsonOutputFormatter

type
  Job = object
    tests: Tests
  Jobs = OrderedTable[string, Job]

let
  # https://docs.github.com/en/actions/learn-github-actions/environment-variables#default-environment-variables
  repo = getEnv"GITHUB_REPOSITORY"
  runId = getEnv"GITHUB_RUN_ID"
  baseUrl = &"""https://api.github.com/repos/{repo}/actions"""
  outputFilename = getEnv"GITHUB_STEP_SUMMARY"

template get(url): untyped =
  client.get url

template getContent(url): untyped =
  client.getContent url

template getJson(url): untyped =
  parseJson getContent url

proc add(a: var Tests, b: Tests) =
  for (name, tests) in b.pairs:
    a[name] = tests

proc getJobs(client: HttpClient, namePeg = peg"@@"): Jobs =
  for job in getJson(&"{baseUrl}/runs/{runId}/jobs")["jobs"]:
    let name = job["name"].getStr
    if name =~ namePeg:
      result[name] = Job()

proc collectResults: Jobs =
  let client = newHttpClient(
    headers = newHttpHeaders({
      "Accept": "application/vnd.github+json",
      "Authorization": "token " & getEnv"GITHUB_TOKEN"
    }))
  result = client.getJobs(peg"'test (' @ ')' $")
  for (name, job) in result.mpairs:
    echo &"{name}:"
    for testResult in walkFiles(name / "*"):
      job.tests.add parseFile(name / testResult).to(Tests)

proc main =
  let jobs = collectResults()
  var report = "# Test Report\n\n"
  # Summary:
  for (name, job) in jobs.pairs:
    for (suiteName, suite) in job.tests.pairs:
      report.add &"{name}: {suiteName} {suite.passed}/{suite.total} (skipped: {suite.skipped})\n"
  writeFile(outputFilename, report)

main()
