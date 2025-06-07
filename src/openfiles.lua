local function open_glob(edit_func, glob_pattern)
    local files = vim.fn.glob(glob_pattern, false, true)

    for _, file in ipairs(files) do
        edit_func(vim.fn.fnameescape(file))
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

    for _, patterns in ipairs(inputs) do
        pcall(open_glob, edit_func, patterns)
    end

    if original_dir ~= "" then
        vim.fn.chdir(original_dir)
    end
end
return open_files_in_dir(...)
