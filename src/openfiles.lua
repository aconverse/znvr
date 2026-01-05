local function cleanup_empty_buffers()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_is_valid(buf) then
            local name = vim.api.nvim_buf_get_name(buf)
            local modified = vim.api.nvim_buf_get_option(buf, 'modified')
            local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

            local is_empty = name == "" and not modified and (#lines == 0 or (#lines == 1 and lines[1] == ""))
            if is_empty then
                local current_buf = vim.api.nvim_get_current_buf()
                local buf_count = #vim.api.nvim_list_bufs()

                if buf ~= current_buf or buf_count > 1 then
                    vim.api.nvim_buf_delete(buf, { force = false })
                end
            end
        end
    end
end

local function open_glob(edit_func, glob_pattern)
    local files = vim.fn.glob(glob_pattern, false, true)

    for _, file in ipairs(files) do
        edit_func(file)
    end
end

local function open_files_in_dir(tabs, directory, inputs)
    local original_dir = ""
    if directory ~= "" then
        local target_dir = vim.fn.expand(directory)
        if vim.fn.isdirectory(target_dir) == 0 then
            print("Directory does not exist: " .. target_dir)
            return
        end
        local success, old_dir = pcall(vim.fn.chdir, target_dir)
        if not success then
            print("Failed to change to directory: " .. target_dir)
            return
        end
        original_dir = old_dir
    end

    local edit_func = vim.cmd.edit
    if tabs then
        edit_func = vim.cmd.tabedit
    end

    for _, pattern in ipairs(inputs) do
        if pattern:find("[%*%?%[]") then
            pcall(open_glob, edit_func, pattern)
        else
            pcall(edit_func, pattern)
        end
    end

    if original_dir ~= "" then
        vim.fn.chdir(original_dir)
    end

    cleanup_empty_buffers()
end
return open_files_in_dir(...)
