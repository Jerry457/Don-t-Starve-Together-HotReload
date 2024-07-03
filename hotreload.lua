local MODENV = env
GLOBAL.setfenv(1, GLOBAL)

if not IsWin32() then
    return
end

HotReload = {}
MODENV.HotReload = HotReload

local UpvalueHelper = require("upvaluehelper")
local FileWatcher = require("filewatcher")

local _require = require

local ClassObjectMap = setmetatable({}, { __mode = "kv" })

local _Class = Class
function Class(...)
    local c = _Class(...)

    local mt = getmetatable(c)
    mt.___call = mt.__call
    mt.__call = function(...)
        local object = mt.___call(...)

        if not ClassObjectMap[c] then
            ClassObjectMap[c] = setmetatable({}, { __mode = "v" })
        end
        table.insert(ClassObjectMap[c], object)

        return object
    end

    return c
end

function HotReload.UpdateClass(class1, class2)
    -- update class base
    if class1._base ~= class2._base then
        for i, v in pairs(class2._base) do
            class1[i] = v
            ClassRegistry[class1][i] = v
        end
        class1._base = class2._base
    end

    -- update class
    for k, v in pairs(class2) do
        if k ~= "_base" and k ~= "__index" and k ~= "__newindex" and k ~= "is_a" and k ~= "is_class" and k ~= "is_instance" then
            if type(v) == "function" and type(class1[k]) == "function" then
                HotReload.UpdateUpvalue(v , class1[k])
                class1[k] = v
            elseif type(v) == "table" and type(class1[k]) == "table" then
                HotReload.UpdateTable(class1[k], v)
            end
        end
    end

    for c, c_inherited in pairs(ClassRegistry) do
        if c._base == class1 then
            for i, v in pairs(class1) do
                c[i] = v
                c_inherited[i] = v
            end
        end
    end

    local mt1 = debug.getmetatable(class1)
    local mt2 = debug.getmetatable(class2)

    if not mt1.___call then
        return
    end

    -- update props
    local props1 = UpvalueHelper.GetUpvalue(mt1.___call, "props")
    local props2 = UpvalueHelper.GetUpvalue(mt2.___call, "props")
    if props1 then
        UpvalueHelper.SetUpvalue(mt1.___call, props2, "props")
    end

    -- update objects
    local objects = ClassObjectMap[class1]
    if not objects then
        return
    end

    -- update objects props
    for _, object in pairs(objects) do
        if class1.is_instance(object) then
            local _ = rawget(object, "_")

            if type(_) == "table" and type(props2) == "table" then
                print("update props")
                for k, v in pairs(props2) do
                    _[k][2] = v
                end
            end
        end
    end
end

function HotReload.UpdateUpvalue(func1, func2)
    assert("function" == type(func1))
    assert("function" == type(func2))

    local upvalue_map = {}
    for i = 1, math.huge do
        local name, value = debug.getupvalue(func1, i)
        if not name then break end
        upvalue_map[name] = value
    end

    -- update new upvalues to target
    for i = 1, math.huge do
        local name, value = debug.getupvalue(func2, i)
        if not name then break end
        if upvalue_map[name] then
            debug.setupvalue(func2, i, upvalue_map[name])
        end
    end
end

function HotReload.UpdateTable(table1, table2)
    assert("table" == type(table1))
    assert("table" == type(table2))

    -- if is class, update class
    if table1.is_class and table1:is_class() and table2 and table2:is_class() then
        return HotReload.UpdateClass(table1, table2)
    end

    for k, v in pairs(table2) do
        if type(v) == "function" and type(table1[k]) == "function" then
            HotReload.UpdateUpvalue(v, table1[k])
            table1[k] = v
        elseif type(v) == "table" and type(table1[k]) == "table" then
            HotReload.UpdateTable(table1[k], v)
        end
    end

    -- update metatable
    local target_meta = debug.getmetatable(table1)
    local new_meta = debug.getmetatable(table2)
    if type(target_meta) == "table" and type(new_meta) == "table" then
        HotReload.UpdateTable(target_meta, new_meta, updated_tables)
    end
end

function HotReload.UpdateModule(module_name)
    local _module = package.loaded[module_name]
    package.loaded[module_name] = nil

    local ok, err = pcall(_require, module_name)
    if not ok then
        package.loaded[module_name] = _module
        print("reload lua file failed.", err)
        return
    end

    local module = package.loaded[module_name]

    if type(module) == "table" and type(_module) == "table" then
        HotReload.UpdateTable(_module, module)
        package.loaded[module_name] = _module
    end
    print("replaced succeed")
end

function require(module_name, ...)
    local no_loaded = package.loaded[module_name] == nil
    local ret = {_require(module_name, ...)}

    if no_loaded then  -- if no loaded
        local path = resolvefilepath_soft("scripts/" .. module_name .. ".lua")
        if path and not path:find("workshop") then
            FileWatcher.WatchFileChange(path, HotReload.UpdateModule, module_name)
        end
    end

    return unpack(ret)
end

-- hot reload prefab file
local _LoadPrefabFile = LoadPrefabFile
function LoadPrefabFile(filename, ...)
    local ret = _LoadPrefabFile(filename, ...)
    if ret then
        for i, val in ipairs(ret) do
            if type(val) == "table" and val.is_a and val:is_a(Prefab) then
                local path = resolvefilepath("scripts/" .. filename .. ".lua")
                if not path:find("workshop") then
                    FileWatcher.WatchFileChange(path, _LoadPrefabFile, filename, ...)
                end
            end
        end
    end
    return ret
end
