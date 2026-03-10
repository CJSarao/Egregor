# Enhanced jq filter for claude-code session logging
# Adds timestamps, severity colors, full details, and better formatting

def timestamp: now | strftime("%H:%M:%S");
def red(s): "\u001b[1;31m\(s)\u001b[0m";
def yellow(s): "\u001b[1;33m\(s)\u001b[0m";
def green(s): "\u001b[1;32m\(s)\u001b[0m";
def cyan(s): "\u001b[1;36m\(s)\u001b[0m";
def magenta(s): "\u001b[1;35m\(s)\u001b[0m";
def dim(s): "\u001b[2m\(s)\u001b[0m";
def first_present($values): $values | map(select(. != null and . != "")) | .[0];
def tool_input_path($tool):
  first_present([$tool.input.file_path, $tool.input.path, $tool.input.filePath, $tool.input.glob, $tool.input.filePattern]);
def tool_command($tool):
  first_present([$tool.input.command, $tool.input.cmd]);
def tool_pattern($tool):
  first_present([$tool.input.pattern, $tool.input.query]);
def preview_lines($text; n):
  $text
  | split("\n") as $lines
  | ($lines | length) as $count
  | ($lines[:n] | map("[" + timestamp + "] " + dim("  " + .)))
  + (if $count > n then ["[" + timestamp + "] " + dim("  ... \($count - n) more lines omitted")] else [] end);
def tool_name_label($state; $tool_use_id):
  $state.tool_names[$tool_use_id] // "Unknown";

def render_tool($tool):
  if $tool.name == "Task" then
    "[" + timestamp + "] " + cyan("[TASK]") + " \($tool.name)",
    "[" + timestamp + "] " + dim("  Description: \($tool.input.description)"),
    "[" + timestamp + "] " + dim("  Delegate to: \($tool.input.subagent_type) (\($tool.input.model))")
  elif $tool.name == "Read" then
    "[" + timestamp + "] " + cyan("[TOOL]") + " \($tool.name)",
    "[" + timestamp + "] " + dim("  File: \(tool_input_path($tool) // "N/A")")
  elif $tool.name == "Edit" or $tool.name == "edit_file" then
    "[" + timestamp + "] " + cyan("[TOOL]") + " \($tool.name)",
    "[" + timestamp + "] " + dim("  File: \(tool_input_path($tool) // "N/A")"),
    "[" + timestamp + "] " + dim("  Lines: \($tool.input.read_range // $tool.input.old_string // "N/A")")
  elif $tool.name == "Write" or $tool.name == "create_file" then
    "[" + timestamp + "] " + cyan("[TOOL]") + " \($tool.name)",
    "[" + timestamp + "] " + dim("  File: \(tool_input_path($tool) // "N/A")")
  elif $tool.name == "Bash" then
    "[" + timestamp + "] " + cyan("[TOOL]") + " \($tool.name)",
    "[" + timestamp + "] " + dim("  Command: \(tool_command($tool) // "N/A")")
  elif $tool.name == "Grep" then
    "[" + timestamp + "] " + cyan("[TOOL]") + " \($tool.name)",
    "[" + timestamp + "] " + dim("  Pattern: \(tool_pattern($tool) // "N/A")"),
    "[" + timestamp + "] " + dim("  Path: \(tool_input_path($tool) // "N/A")")
  elif $tool.name == "Glob" or $tool.name == "glob" then
    "[" + timestamp + "] " + cyan("[TOOL]") + " \($tool.name)",
    "[" + timestamp + "] " + dim("  Pattern: \(tool_input_path($tool) // "N/A")")
  else
    "[" + timestamp + "] " + cyan("[TOOL]") + " \($tool.name)",
    "[" + timestamp + "] " + dim("  Input: \($tool.input | tostring)")
  end;

def render_result($state; $result):
  if (($result.content | type) == "string") then
    if $result.content == "" then
      "[" + timestamp + "] " + green("[RESULT]") + " (empty)"
    else
      (if $result.is_error == true then
        "[" + timestamp + "] " + red("[RESULT ERROR]")
       else
        "[" + timestamp + "] " + green("[RESULT]")
       end),
      (if $result.tool_use_id then
        "[" + timestamp + "] " + dim("  Tool: \(tool_name_label($state; $result.tool_use_id))")
       else empty end),
      (preview_lines($result.content; 2) | join("\n"))
    end
  else
    (($result.tool_use_result // $result) as $tool_result |
    (if ($tool_result.is_error // false) then
      "[" + timestamp + "] " + red("[RESULT ERROR]")
    else
      "[" + timestamp + "] " + green("[RESULT]")
    end),
    (if $result.tool_use_id then
      "[" + timestamp + "] " + dim("  Tool: \(tool_name_label($state; $result.tool_use_id))")
     else empty end),
    (if $tool_result.file then
      "[" + timestamp + "] " + dim("  File: \($tool_result.file.filePath)"),
      "[" + timestamp + "] " + dim("  Lines: \($tool_result.file.numLines // "N/A")")
    elif $tool_result.filePath then
      "[" + timestamp + "] " + dim("  File: \($tool_result.filePath)")
    elif $tool_result.stdout or $tool_result.stderr then
      (($tool_result.stdout // "") + (if ($tool_result.stdout and $tool_result.stderr) then "\n" else "" end) + ($tool_result.stderr // ""))
      | if . == "" then
          "[" + timestamp + "] " + dim("  (no stdout/stderr)")
        else
          preview_lines(.; 2) | join("\n")
        end
    else
      "[" + timestamp + "] " + dim("  Data: \($tool_result | tostring)")
    end))
  end;

def render_event($state; $event):
  if $event.type == "system" and $event.subtype == "init" then
    "[" + timestamp + "] " + cyan("=== Claude Code Session Started ==="),
    "[" + timestamp + "] " + dim("Working Directory: \($event.cwd)"),
    "[" + timestamp + "] " + dim("Model: \($event.model)"),
    "[" + timestamp + "] " + dim("Tools Available: \($event.tools | length) tools"),
    "[" + timestamp + "] " + dim("Session ID: \($event.session_id)"),
    ""
  elif $event.type == "assistant" and $event.message.content then
    ($event.message.content[] |
      if .type == "text" then
        "[" + timestamp + "] " + magenta("[CLAUDE]") + " \(.text)"
      elif .type == "thinking" then
        empty
      elif .type == "tool_use" then
        render_tool(.)
      else
        empty
      end
    )
  elif $event.type == "user" and $event.message.content then
    ($event.message.content[] |
      if .type == "tool_result" then
        render_result($state; .)
      elif .type == "tool_use_error" then
        "[" + timestamp + "] " + red("[ERROR]") + " Tool execution failed",
        "[" + timestamp + "] " + red("  \(.content)")
      elif .type == "error" then
        "[" + timestamp + "] " + red("[ERROR]") + " \(.content)"
      else
        empty
      end
    )
  else
    empty
  end;

foreach inputs as $event (
  { tool_names: {} };
  if $event.type == "assistant" and $event.message.content then
    reduce ($event.message.content[] | select(.type == "tool_use")) as $tool (.;
      .tool_names[$tool.id] = $tool.name
    )
  else
    .
  end;
  render_event(.; $event)
)
