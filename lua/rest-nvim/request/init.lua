local utils = require("rest-nvim.utils")
local path = require("plenary.path")
local log = require("plenary.log").new({ plugin = "rest.nvim", level = "warn" })

-- get_importfile returns in case of an imported file the absolute filename
-- @param bufnr Buffer number, a.k.a id
-- @param stop_line Line to stop searching
local function get_importfile_name(bufnr, start_line, stop_line)
  -- store old cursor position
  local oldpos = vim.fn.getcurpos()
  utils.go_to_line(bufnr, start_line)

  local import_line = vim.fn.search("^<", "n", stop_line)
  -- restore old cursor position
  utils.go_to_line(bufnr, oldpos[2])

  if import_line > 0 then
    local fileimport_string
    local fileimport_line
    fileimport_line = vim.api.nvim_buf_get_lines(bufnr, import_line - 1, import_line, false)
    fileimport_string = string.gsub(fileimport_line[1], "<", "", 1)
      :gsub("^%s+", "")
      :gsub("%s+$", "")
    -- local fileimport_path = path:new(fileimport_string)
    -- if fileimport_path:is_absolute() then
    if path:new(fileimport_string):is_absolute() then
      return fileimport_string
    else
      local file_dirname = vim.fn.expand("%:p:h")
      local file_name = path:new(path:new(file_dirname), fileimport_string)
      return file_name:absolute()
    end
  end
  return nil
end

-- get_body retrieves the body lines in the buffer and then returns
-- either a raw string with the body if it is JSON, or a filename. Plenary.curl can distinguish
-- between strings with filenames and strings with the raw body
-- @param bufnr Buffer number, a.k.a id
-- @param start_line Line where body starts
-- @param stop_line Line where body stops
local function get_body(bufnr, start_line, stop_line)
  if start_line >= stop_line then
    return
  end

  -- first check if the body should be imported from an external file
  local importfile = get_importfile_name(bufnr, start_line, stop_line)
  local lines
  if importfile ~= nil then
    if not utils.file_exists(importfile) then
      error("import file " .. importfile .. " not found")
    end
    lines = utils.read_file(importfile)
  else
    lines = vim.api.nvim_buf_get_lines(bufnr, start_line, stop_line, false)
  end

  local body = ""
  -- nvim_buf_get_lines is zero based and end-exclusive
  -- but start_line and stop_line are one-based and inclusive
  -- magically, this fits :-) start_line is the CRLF between header and body
  -- which should not be included in the body, stop_line is the last line of the body
  for _, line in ipairs(lines) do
    -- Ignore commented lines with and without indent
    if not utils.contains_comments(line) then
      body = body .. utils.replace_vars(line)
    end
  end

  return body
end
-- is_request_line checks if the given line is a http request line according to RFC 2616
local function is_request_line(line)
  local http_methods = { "GET", "POST", "PUT", "PATCH", "DELETE" }
  for _, method in ipairs(http_methods) do
    if line:find("^" .. method) then
      return true
    end
  end
  return false
end

-- get_headers retrieves all the found headers and returns a lua table with them
-- @param bufnr Buffer number, a.k.a id
-- @param start_line Line where the request starts
-- @param end_line Line where the request ends
local function get_headers(bufnr, start_line, end_line)
  local headers = {}
  local body_start = end_line

  -- Iterate over all buffer lines starting after the request line
  for line_number = start_line + 1, end_line do
    local line = vim.fn.getbufline(bufnr, line_number)
    local line_content = line[1]

    -- message header and message body are seperated by CRLF (see RFC 2616)
    -- for our purpose also the next request line will stop the header search
    if is_request_line(line_content) or line_content == "" then
      body_start = line_number
      break
    end
    if not line_content:find(":") then
      log.warn("Missing Key/Value pair in message header. Ignoring line: ", line_content)
      goto continue
    end

    local header = utils.split(line_content, ":")
    if not utils.contains_comments(header[1]) then
      headers[header[1]:lower()] = utils.replace_vars(header[2])
    end
    ::continue::
  end

  return headers, body_start
end

-- start_request will find the request line (e.g. POST http://localhost:8081/foo)
-- of the current request and returns the linenumber of this request line.
-- The current request is defined as the next request line above the cursor
-- @param bufnr The buffer nummer of the .http-file
local function start_request()
  return vim.fn.search("^GET\\|^POST\\|^PUT\\|^PATCH\\|^DELETE", "cbn", 1)
end

-- end_request will find the next request line (e.g. POST http://localhost:8081/foo)
-- and returns the linenumber before this request line or the end of the buffer
-- @param bufnr The buffer nummer of the .http-file
local function end_request(bufnr)
  -- store old cursor position
  local curpos = vim.fn.getcurpos()
  local linenumber = curpos[2]
  local oldlinenumber = linenumber

  -- start searching for next request from the next line
  -- as the current line does contain the current, not the next request
  if linenumber < vim.fn.line("$") then
    linenumber = linenumber + 1
  end
  utils.go_to_line(bufnr, linenumber)

  local next = vim.fn.search("^GET\\|^POST\\|^PUT\\|^PATCH\\|^DELETE", "cn", vim.fn.line("$"))

  -- restore cursor position
  utils.go_to_line(bufnr, oldlinenumber)
  return next > 1 and next - 1 or vim.fn.line("$")
end

-- parse_url returns a table with the method of the request and the URL
-- @param stmt the request statement, e.g., POST http://localhost:3000/foo
local function parse_url(stmt)
  local parsed = utils.split(stmt, " ")
  return {
    method = parsed[1],
    -- Encode URL
    url = utils.encode_url(utils.replace_vars(parsed[2])),
  }
end

local M = {}
M.get_current_request = function()
  local bufnr = vim.api.nvim_win_get_buf(0)

  local start_line = start_request()
  if start_line == 0 then
    error("No request found")
  end
  local end_line = end_request()
  utils.go_to_line(bufnr, start_line)

  local parsed_url = parse_url(vim.fn.getline(start_line))

  local headers, body_start = get_headers(bufnr, start_line, end_line)

  local body = get_body(bufnr, body_start, end_line)

  return {
    method = parsed_url.method,
    url = parsed_url.url,
    headers = headers,
    body = body,
  }
end

return M
