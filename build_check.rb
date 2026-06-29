#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Convert a lumitrace JSON report into a GitHub "create a check run" payload,
# printed as JSON on stdout.
#
#   build_check.rb <lumitrace.json> <head_sha> <root> [details_url]
#
# Annotation strategy (see the project plan): annotations are a *curated few*,
# not every traced line. We surface uncovered changed lines first (most useful
# in review), then a capped number of value highlights. The full data lives in
# the summary table and, when configured, the details_url report.

require "json"

# GitHub accepts at most 50 annotations per check-run API request. We keep a
# single request here; callers wanting more would PATCH additional batches.
MAX_ANNOTATIONS = 50
# Cap value highlights (one per line) shown in the summary.
HIGHLIGHT_LIMIT = 10

# The Check summary renders as markdown, and file names / expression names /
# recorded values come from the traced code (PR-author-controlled on a fork).
# Neutralise content so it can't break out of its code span / table cell:
#  - md_code: collapse control chars (newlines break table rows), turn backticks
#    into a look-alike (they close a code span). Safe inside a list code span.
#  - md_table_code: additionally entity-escape pipes (they split table cells).
def md_code(s, limit = 160)
  s = s.to_s.gsub(/[[:cntrl:]]+/, " ").gsub("`", "ʼ")
  s.length > limit ? "#{s[0, limit]}…" : s
end

def md_table_code(s, limit = 120)
  md_code(s, limit).gsub("|", "&#124;")
end

json_path, head_sha, root, details_url = ARGV
if json_path.nil? || head_sha.nil? || root.nil?
  abort "usage: build_check.rb <lumitrace.json> <head_sha> <root> [details_url]"
end

check_name = ENV.fetch("LUMITRACE_CHECK_NAME", "lumitrace")
data = JSON.parse(File.read(json_path))
events = data["events"] || []
coverage = data["coverage"] || []

root_prefix = "#{root.chomp("/")}/"
relativize = lambda do |file|
  file.start_with?(root_prefix) ? file.delete_prefix(root_prefix) : file
end

# Best-available value description for an event, across collect modes.
value_of = lambda do |event|
  if (v = event["last_value"])
    "#{v["type"]} #{v["preview"]}"
  elsif (vals = event["sampled_values"]) && !vals.empty?
    last = vals.last
    "#{last["type"]} #{last["preview"]}"
  else
    (event["types"] || {}).keys.join(" | ")
  end
end

uncovered = events.select { |e| e["total"].to_i.zero? }
covered = events.select { |e| e["total"].to_i.positive? }

# Inline annotations are reserved for lines that need attention — currently
# uncovered changed lines (total==0). Recorded values are deliberately NOT
# annotated inline: a value on every changed line buries the diff. They live in
# the summary highlights (Checks tab) and the full HTML report instead.
#
# Paths/lines are validated before they reach GitHub: a path outside the repo
# (absolute, or with `..`/control chars) or a non-positive line number would make
# the whole check-run create call fail, so such annotations are dropped instead.
seen_lines = {} # one annotation per (file, line)
annotations = uncovered.filter_map do |e|
  path = relativize.call(e["file"].to_s)
  line = e["start_line"].to_i
  next if line < 1
  next if path.empty? || path.start_with?("/") ||
          path.split("/").include?("..") || path.match?(/[[:cntrl:]]/)

  key = [path, line]
  next if seen_lines[key]

  seen_lines[key] = true
  {
    "path" => path,
    "start_line" => line,
    "end_line" => line,
    "annotation_level" => "warning",
    "title" => "lumitrace: uncovered",
    "message" => "This changed line was never executed in this run (total=0)."
  }
end

annotations_truncated = annotations.size > MAX_ANNOTATIONS
annotations = annotations.first(MAX_ANNOTATIONS)

# Value highlights for the summary only (Checks tab, never inline on the diff).
# One representative value per changed line: the outermost expression — the one
# starting earliest on the line, widest on ties — so nested sub-expressions
# don't repeat a line. Keeps the summary compact.
by_line = {}
covered.each do |e|
  key = [e["file"], e["start_line"]]
  cur = by_line[key]
  better =
    cur.nil? ||
    e["start_col"].to_i < cur["start_col"].to_i ||
    (e["start_col"].to_i == cur["start_col"].to_i &&
     ([e["end_line"].to_i, e["end_col"].to_i] <=> [cur["end_line"].to_i, cur["end_col"].to_i]) > 0)
  by_line[key] = e if better
end
all_highlights = by_line.values.sort_by { |e| [relativize.call(e["file"]), e["start_line"]] }
highlights = all_highlights.first(HIGHLIGHT_LIMIT)
highlights_truncated = all_highlights.size > HIGHLIGHT_LIMIT

# Summary markdown.
summary = +"**Lumitrace** traced #{events.size} expression(s) in the changed range.\n\n"
unless coverage.empty?
  summary << "| File | Covered | % |\n|---|---|---|\n"
  coverage.each do |c|
    summary << "| `#{md_table_code(relativize.call(c["file"]))}` | " \
               "#{c["covered_lines"].to_i}/#{c["total_lines"].to_i} | #{md_table_code(c["coverage_percent"].to_s)}% |\n"
  end
end
summary << "\n⚠️ #{uncovered.size} changed line(s) never executed.\n" unless uncovered.empty?
summary << "\n_Showing the first #{MAX_ANNOTATIONS} of #{uncovered.size} uncovered annotations._\n" if annotations_truncated
unless highlights.empty?
  summary << "\n**Highlights**\n"
  highlights.each do |e|
    loc = "#{md_code(relativize.call(e["file"]))}:#{e["start_line"].to_i}"
    name = e["name"] ? "`#{md_code(e["name"])}` " : ""
    summary << "- `#{loc}` #{name}→ `#{md_code(value_of.call(e))}`\n"
  end
  summary << "- …and #{all_highlights.size - HIGHLIGHT_LIMIT} more\n" if highlights_truncated
end
if details_url && !details_url.empty?
  summary << "\n[Full report ↗](#{details_url}) · [JSON for tooling/AI](#{details_url}/data)\n"
end

title =
  if uncovered.empty?
    "#{events.size} expressions traced"
  else
    "#{uncovered.size} uncovered · #{events.size} traced"
  end

payload = {
  "name" => check_name,
  "head_sha" => head_sha,
  "status" => "completed",
  # Informational only: never block CI on a trace.
  "conclusion" => "neutral",
  "output" => {
    "title" => title,
    "summary" => summary,
    "annotations" => annotations
  }
}
payload["details_url"] = details_url if details_url && !details_url.empty?

puts JSON.pretty_generate(payload)
