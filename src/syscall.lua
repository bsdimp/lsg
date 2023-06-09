--
-- SPDX-License-Identifier: BSD-2-Clause
--
-- Copyright (c) 2023 Warner Losh <imp@bsdimp.com>
--

scarg = require("scarg")
util = require("util")

local syscall = {}

syscall.__index = syscall

syscall.known_flags = util.Set {
	"STD",
	"OBSOL",
	"RESERVED",
	"UNIMPL",
	"NODEF",
	"NOARGS",
	"NOPROTO",
	"NOSTD",
	"NOTSTATIC",
	"CAPENABLED",
	"SYSMUX",
}

-- All compat option entries should have five entries:
--	definition: The preprocessor macro that will be set for this
--	compatlevel: The level this compatibility should be included at.  This
--	    generally represents the version of FreeBSD that it is compatible
--	    with, but ultimately it's just the level of mincompat in which it's
--	    included.
--	flag: The name of the flag in syscalls.master.
--	prefix: The prefix to use for _args and syscall prototype.  This will be
--	    used as-is, without "_" or any other character appended.
--	descr: The description of this compat option in init_sysent.c comments.
-- The special "stdcompat" entry will cause the other five to be autogenerated.
local compat_option_sets = {
	native = {
		{
			definition = "COMPAT_43",
			compatlevel = 3,
			flag = "COMPAT",
			prefix = "o",
			descr = "old",
		},
		{ stdcompat = "FREEBSD4" },
		{ stdcompat = "FREEBSD6" },
		{ stdcompat = "FREEBSD7" },
		{ stdcompat = "FREEBSD10" },
		{ stdcompat = "FREEBSD11" },
		{ stdcompat = "FREEBSD12" },
		{ stdcompat = "FREEBSD13" },
	},
}

-- XXX need to sort out how to do compat stuff...
-- native is the only compat thing
-- Also need to figure out the different other things that 'filter' system calls
-- since the abi32 stuff does that.

local function check_type(line, t)
	for k, v in pairs(t) do
--		if not syscall.known_flags[v] and
--		   not v:match("^COMPAT") then
--			util.abort(1, "Bad type: " .. v)
--		end
	end
end

local native = 1000000

-- Return the symbol name for this system call
function syscall:symbol()
	local c = self:compat_level()
	if self.type.OBSOL then
		return "obs_" .. self.name
	end
	if self.type.RESERVED then
		return "reserved #" .. tostring(self.num)
	end
	if self.type.UNIMPL then
		return "unimp_" .. self.name
	end
	if c == 3 then
		return "o" .. self.name
	end
	if c < native then
		return "freebsd" .. tostring(c) .. "_" .. self.name
	end
	return self.name
end

-- Return the compatibility level for this system call
-- 0 is obsolete
-- < 0 is this isn't really a system call we care about
-- 3 is 4.3BSD in theory, but anything before FreeBSD 4
-- >= 4 FreeBSD version this system call was replaced with a new version
function syscall:compat_level()
	if self.type.UNIMPL or self.type.RESERVED or self.type.NODEF then
		return -1
	elseif self.type.OBSOL then
		return 0
	elseif self.type.COMPAT then
		return 3
	end
	for k, v in pairs(self.type) do
		local l = k:match("^COMPAT(%d+)")
		if l ~= nil then
			return tonumber(l)
		end
	end
	return native
end

--
-- We build up the system call one line at a time, as we pass through 4 states
-- We don't have an explicit state name here, but maybe we should
--
function syscall:add(line)
	local words = util.split(line, "%S+")

	-- starting
	if self.num == nil then
		-- sort out range somehow XXX
		-- Also, where to put validation of no skipped syscall #? XXX
		self.num = words[1]
		self.audit = words[2]
		self.type = util.SetFromString(words[3], "[^|]+")
		check_type(line, self.type)
		self.name = words[4]
		-- These next three are optional, and either all present or all absent
		self.altname = words[5]
		self.alttag = words[6]
		self.altrtyp = words[7]
		return self.name ~= "{"
	end

	-- parse function name
	if self.name == "{" then
		-- Expect line is "type syscall(" or "type syscall(void);"
		if #words ~= 2 then
			util.abort(1, "Malformed line " .. line)
		end
		self.rettype = words[1]
		self.name = words[2]:match("([%w_]+)%(")
		if words[2]:match("%);$") then
			self.expect_rbrace = true
		end
		return false
	end

	-- eating args
	if not self.expect_rbrace then
		-- We're looking for (another) argument
		-- xxx copout for the moment and just snarf the argument
		-- some have trailing , on last arg
		if line:match("%);$") then
			self.expect_rbrace = true
			return false
		end

		local arg = scarg:new({ }, line)
		table.insert(self.args, arg)
		return false
	end

	-- state wrapping up, can only get } here
	if not line:match("}$") then
		util.abort(1, "Expected '}' found '" .. line .. "' instead.")
	end
	return true
end

function syscall:new(obj)
	obj = obj or { }
	setmetatable(obj, self)
	self.__index = self

	self.expect_rbrace = false
	self.args = { }

	return obj
end

-- Make a copy (a shallow one is fine) of `self` and replace
-- the system call number (which is likely a range) with num
-- (which should be a number)
function syscall:clone(num)
	local obj = syscall:new(obj)

	-- shallow copy
	for k, v in pairs(self) do
		obj[k] = v
	end
	obj.num = num	-- except override range
	return obj
end

-- As we're parsing the system calls, there's two types. Either we have a
-- specific one, that's a assigned a number, or we have a range for things like
-- reseved system calls. this function deals with both knowing that the specific
-- ones are more copy and so we should just return the object we just made w/o
-- an extra clone.
function syscall:iter()
	local s = tonumber(self.num)
	local e
	if s == nil then
		s, e = string.match(self.num, "(%d+)%-(%d)")
		return function ()
			if s <= e then
				s = s + 1
				return self:clone(s - 1)
			end
		end
	else
		e = s
		self.num = s	-- Replace string with number, like the clones
		return function ()
			if s == e then
				s = e + 1
				return self
			end
		end
	end
end

return syscall
