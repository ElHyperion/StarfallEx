/******************************************************************************\
  Starfall Compiler for Garry's Mod
  By Colonel Thirty Two
  initrd.gz@gmail.com
  
  Based on the Expression 2 Compiler by
  Andreas "Syranide" Svensson, me@syranide.com
\******************************************************************************/


SF_Compiler = SF_Compiler or {}
SF_Compiler.__index = SF_Compiler

function SF_Compiler:Error(message, instr)
	error(message .. " at line " .. instr[2][1] .. ", char " .. instr[2][2], 0)
end

function SF_Compiler:Process(...)
	local instance = setmetatable({},SF_Compiler)
	return pcall(SF_Compiler.Execute,instance,...)
	--return instance:Execute(...)
end

function SF_Compiler:Execute(root, inputs, outputs, params)
	self.contexts = {}
	self.inputs = inputs
	self.outputs = outputs
	self.params = params
	self.code = ""
	
	self:PushContext("do")
	
	local first_instr = "Instr"..string.upper(root[1])
	if not SF_Compiler[first_instr] then
		error("No such instruction: "..first_instr)
	end
	SF_Compiler[first_instr](self, root)
	self:PopContext()

	-- Debug code
	if #self.contexts > 0 then
		error("SF Internal Error: Did not pop all contexts.")
	end
	
	return self.code
end

function SF_Compiler:Evaluate(args, index)
	
	local name = string.upper(args[index + 2][1])
	local ex = SF_Compiler["Instr" .. name](self, args[index + 2])
	return ex
end

-- ---------------------------------------- --
-- Context Management                       --
-- ---------------------------------------- --
function SF_Compiler:PushContext(beginning)
	local tbl = {
		vars = {},
		code = "",
		cost = 0
	}
	self:AddCode((beginning or "").."\n")
	self.contexts[#self.contexts + 1] = tbl
end

function SF_Compiler:PopContext(ending)

	local tbl = self.contexts[#self.contexts]
	self.contexts[#self.contexts] = nil

	local varsdef = "local "
	for var,_ in pairs(tbl.vars) do
		varsdef = varsdef .. var .. ", "
	end
	if varsdef:len() > 6 then self:AddCode(varsdef:sub(1,varsdef:len()-2).."\n") end

	self:AddCode("SF_Self:IncrementCost("..tbl.cost..")\n")
	self:AddCode(tbl.code.."\n"..(ending or "end").."\n")
end

function SF_Compiler:CurrentContext()
	return self.contexts[#self.contexts]
end

function SF_Compiler:AddCode(code)
	-- Adds code to the current context.
	-- ONLY statement instructions should call this!
	--if not code then return end
	local tbl = self.contexts[#self.contexts]
	if tbl then
		tbl.code = tbl.code .. code
	else
		self.code = self.code .. code
	end
end

function SF_Compiler:IncrementCost(cost)
	local tbl = self.contexts[#self.contexts]
	tbl.cost = tbl.cost + cost
end

-- ---------------------------------------- --
-- Variable Management                      --
-- ---------------------------------------- --

function SF_Compiler:DefineVar(name, islocal)
	-- Defines variable "name". If islocal is true, then creates it in
	-- the current context. If false, does a trace through each context
	-- layer for the variable name, and use that context's varable (or
	-- defines it in global if it hasn't been defined yet.)
	if islocal then
		self:CurrentContext().vars[name] = true
	elseif not self:IsVarDefined(name) then
		self.contexts[1].vars[name] = true
	end
end

function SF_Compiler:IsVarDefined(name)
	for i=#self.contexts,1,-1 do
		if self.contexts[i].vars[name] then return true end
	end
	return false
end

-- ---------------------------------------- --
-- Instructions - Statements                --
-- ---------------------------------------- --

function SF_Compiler:InstrSEQ(args)
	for i=1,#args-2 do
		local code = self:Evaluate(args,i)
		if code then self:AddCode(code) end
	end
end

function SF_Compiler:InstrASSIGN(args)
	local var = args[3]
	local islocal = args[5]
	
	self:DefineVar(var, islocal)
	
	if args[4] then
		local ex = self:Evaluate(args,2)
		self:AddCode(self:GenerateLua_VariableReference(var) .. " = " .. ex .. "\n")
	end
end

function SF_Compiler:InstrIF(args)
	local firstcond, elifcond, elsecond = args[3], args[4], args[5]
	
	self:AddCode("if ("..self:Evaluate(firstcond,-1)..") then\n")
	self:PushContext()
	self:Evaluate(firstcond,0)
	self:PopContext("")
	
	if elifcond[1] ~= nil then
		for _,cond in ipairs(elifcond) do
			self:AddCode("elseif ("..self:Evaluate(cond,-1)..") then\n")
			self:PushContext()
			self:Evaluate(cond,0)
			self:PopContext("")
		end
	end
	
	if elsecond ~= nil then
		self:AddCode("else\n")
		self:PushContext()
		self:Evaluate(args,3)
		self:PopContext("")
	end
	
	self:AddCode("end\n")
end

function SF_Compiler:InstrWHILE(args)
	self:AddCode("while ("..self:Evaluate(args,1)..") do\n")
	self:PushContext()
	self:Evaluate(args,2)
	self:PopContext()
end

function SF_Compiler:InstrFOR(args)
	local varname = args[3]
	
	self:AddCode("for "..varname.." = ("..self:Evaluate(args,2).."), ("..self:Evaluate(args,3)..")")
	if args[6] then
		self:AddCode(", ("..self:Evaluate(args,4)..")")
	end
	self:AddCode(" do\n")
	self:PushContext()
	self:Evaluate(args,5)
	self:PopContext()
end

-- ---------------------------------------- --
-- Instructions - Expression                --
-- ---------------------------------------- --

function SF_Compiler:InstrVAR(args)
	local name = args[3]
	return self:GenerateLua_VariableReference(name)
end

function SF_Compiler:InstrNUM(args)
	local num = args[3]

	return num, "number"
end

function SF_Compiler:InstrSTR(args)
	local str = args[3]

	str = str:Replace('"',"\\\""):Replace("\n","\\n"):Replace("\\","\\\\")
	str = "\""..str.."\""

	return str, "string"
end

function SF_Compiler:InstrGROUP(args)
	local ex = self:Evaluate(args,1)
	return "("..ex..")"
end

function SF_Compiler:InstrCALL(args)
	local ex = self:Evaluate(args,1)
	local instrs = args[4]

	local exprs = {}

	for i=1,#args[4] do
		local ex = self:Evaluate(args[4], i - 2)
		exprs[#exprs + 1] = ex
	end


end

function SF_Compiler:InstrINDX(args)
	local ex1 = self:Evaluate(args,2)
	local isConstant = args[3]
	
	if isConstant then
		-- Var.name
		return ex1 .. "." .. args[5]
	else
		-- Var[expr]
		return ex1 .. "[" .. self:Evaluate(args,3) .. "]"
	end
end

function SF_Compiler:InstrNEGATE(args)
	return "-" .. self:Evaluate(args,1)
end

function SF_Compiler:InstrNOT(args)
	return "not " .. self:Evaluate(args,1)
end

local operators = {
	["and"] = "and",
	["or"] = "or",
	["not"] = "not",
	
	add = "+",
	sub = "-",
	mul = "*",
	div = "/"
}

for name, keyword in pairs(operators) do
	SF_Compiler["Instr"..string.upper(name)] = function(self, args)
		local e1, e2 = self:Evaluate(args,1), self:Evaluate(args,2)
		return e1 .. " "..keyword.." "..e2
	end
end

-- ---------------------------------------- --
-- Lua Generation Functions                 --
-- ---------------------------------------- --

function SF_Compiler:GenerateLua_VariableReference(name)
	for i = #self.contexts, 1, -1 do
		if self.contexts[i].vars[name] then
			return name
		end
	end

	if self.outputs[name] then return "SF_Ent.outputs[\"" .. name .. "\"]" end
	if self.inputs[name] then return "SF_Ent.inputs[\"" .. name .. "\"]" end

	error("Internal Error: Tried to generate Lua code for undefined variable \""..name.."\"! Post your code & this error at wiremod.com.")
end