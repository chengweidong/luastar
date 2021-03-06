#!   /usr/bin/env lua
--[[

--]]
--require('mobdebug').start("127.0.0.1")

local Request = require("luastar.core.request")
local Response = require("luastar.core.response")
local db_monitor = require("luastar.db.monitor")

-- 执行变量
local execute_var = {
    stop = false,
    status = 200
}

function init()
    -- 初始化应用包路径
    luastar_context.init_pkg_path()
    -- 获取路由
    execute_var["route"] = luastar_context.getRoute()
    execute_var["ctrl_config"] = execute_var["route"]:getRoute(ngx.var.uri)
    if not execute_var["ctrl_config"] then
        ngx.log(ngx.ERR, "no ctrl find for : ", ngx.var.uri)
        execute_var["stop"] = true
        execute_var["status"] = 404
        return
    end
    -- 加载ctrl
    local ok, ctrl = pcall(require, execute_var["ctrl_config"].class)
    if not ok then
        ngx.log(ngx.ERR, "ctrl import fail :", ctrl)
        execute_var["stop"] = true
        execute_var["status"] = 404
        return
    end
    execute_var["ctrl"] = ctrl
    -- 初始化输入输出
    ngx.ctx.request = Request:new()
    ngx.ctx.response = Response:new()
    -- 获取拦截器
    execute_var["interceptorAry"] = execute_var["route"]:getInterceptor(ngx.var.uri)
end

function content()
    init()
    if execute_var["stop"] then
        -- openresty/1.7.10.1及以前版本的bug
        -- 必须调用ngx.req.read_body()或ngx.req.discard_body()处理请求体
        -- 因为第一个请求的请求体如果没有读取，会被错误地当作下一个请求的请求头来解析
        ngx.req.discard_body()
        ngx.exit(execute_var["status"])
        return
    end
    if execute_var["ctrl"].new then
        execute_ctrl_new()
    else
        execute_ctrl_fun()
    end
    -- 监控数据库连接
    db_monitor.check("redis_connect", "mysql_connect")
    ngx.ctx.response:finish()
    ngx.req.discard_body()
end

function execute_ctrl_new()
    local interceptor_ok, interceptor_msg = execute_before()
    if not interceptor_ok then
        ngx.log(ngx.INFO, "interceptor ctrl success.")
        ngx.ctx.response:writeln(interceptor_msg)
        return
    end
    local ctrl_instance = execute_var["ctrl"]:new()
    local ctrl_method = ctrl_instance[execute_var["ctrl_config"].method]
    if ctrl_method and _.isFunction(ctrl_method) then
        local call_ok, err_info = pcall(ctrl_method, ctrl_instance, ngx.ctx.request, ngx.ctx.response)
        execute_after(call_ok, err_info)
    else
        ngx.log(ngx.ERR, "ctrl has no method.")
    end
end

function execute_ctrl_fun()
    local interceptor_ok, interceptor_msg = execute_before()
    if not interceptor_ok then
        ngx.log(ngx.INFO, "interceptor ctrl success.")
        ngx.ctx.response:writeln(interceptor_msg)
        return
    end
    local ctrl = execute_var["ctrl"]
    local ctrl_method = ctrl[execute_var["ctrl_config"].method]
    if ctrl_method and _.isFunction(ctrl_method) then
        local call_ok, err_info = pcall(ctrl_method, ngx.ctx.request, ngx.ctx.response)
        execute_after(call_ok, err_info)
    else
        ngx.log(ngx.ERR, "ctrl has no method.")
    end
end

function execute_before()
    if _.size(execute_var["interceptorAry"]) == 0 then
        return true, "no interceptor."
    end
    local call_ok, interceptor, rs_ok = true, nil, true
    for key, value in pairs(execute_var["interceptorAry"]) do
        call_ok, interceptor = pcall(require, value)
        if call_ok and _.isFunction(interceptor["beforeHandle"]) then
            call_ok, rs_ok, rs_msg = pcall(interceptor["beforeHandle"])
            if call_ok then
                -- 有一个返回失败，则返回
                if not rs_ok then
                    return false, rs_msg or "intercept by interceptor."
                end
            else
                ngx.log(ngx.ERR, "interceptor call beforeHandle fail : ", rs_ok)
            end
        else
            ngx.log(ngx.ERR, "interceptor require fail : ", interceptor)
        end
    end
    return true, "not intercept by interceptor."
end

function execute_after(ctrl_call_ok, err_info)
    if not ctrl_call_ok then
        ngx.log(ngx.ERR, "ctrl execute error : ", err_info)
    end
    if _.size(execute_var["interceptorAry"]) == 0 then
        return
    end
    local call_ok, interceptor = true, nil
    for key, value in pairs(execute_var["interceptorAry"]) do
        call_ok, interceptor = pcall(require, value)
        if call_ok and _.isFunction(interceptor["afterHandle"]) then
            pcall(interceptor["afterHandle"], ctrl_call_ok, err_info)
        else
            ngx.log(ngx.ERR, "interceptor require fail : ", interceptor)
        end
    end
end

-- 执行
content()

--require('mobdebug').done()