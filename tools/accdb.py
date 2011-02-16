#!/usr/bin/env python2
# Account and password database. For my own internal use.

"""
General syntax:

= entry name
; comments
<tab>	key = value
<tab>	+ flag, other:flag, another:flag

Shorthands:
 * Lines starting with "+" will be added as flags.
 * 'u', 'p', and '@' expand to 'login', 'password', and 'uri'.

Misc syntax notes:
 * Both "=" and ": " are accepted as separators. (Only one, however, is output
   when rewriting the database.)

Database will be rewritten and all shorthands expanded if any change is made,
also when doing 'accdb touch'.
"""
import os
import sys
import fnmatch
import shlex
from cmd import Cmd

class Record(dict):
	def __init__(self, *args, **kwargs):
		self.flags = set()
		self.comment = []
		self.pos = None
		dict.__init__(self, *args, **kwargs)

	def __str__(self, full=True):
		sep = ": "
		out = ""
		out += "= %s\n" % self["Name"]
		for line in self.comment:
			out += "; %s\n" % line
		for key in Database.sort_fields(self.keys(), full):
			if key in ("Name", "comment"):
				continue
			if isinstance(self[key], str):
				values = [self[key]]
			else:
				values = self[key]
			for val in values:
				out += "\t%s\n" % sep.join((key, val))
		if full and len(self.flags) > 0:
			cur = []
			for f in sorted(self.flags):
				if sum(len(x)+2 for x in cur) + len(f) >= 70:
					out += "\t+ %s\n" % ", ".join(cur)
					cur = []
				cur.append(f)
			if len(cur):
				out += "\t+ %s\n" % ", ".join(cur)
		return out

	def keys(self):
		return dict.keys(self)

	def names(self):
		n = [self["Name"]]
		for f in Database.fields["object"]:
			if f in self:
				n.extend(self[f])
		return map(str.lower, n)
	
	def flag(self, *flags):
		self.flags |= set(flags)

class Database():
	fields = dict(
		object		= ("host", "uri"),
		username	= ("login", "nic-hdl"),
		password	= ("pass",),
		email		= ("email",),
	)
	field_order = "object", "username", "password", "email"
	next_pos = 1

	def __init__(self, path):
		self.path = path
		if self.path:
			self.data = self.parse(self.path)
		self.modified = False

	def parse_line(self, line, cur, lineno="stdin"):
		if line.startswith(";"):
			# comment
			val = line[1:].strip()
			cur.comment.append(val)
		elif line.startswith("+"):
			# flags
			val = line[1:].lower().replace(",", " ").split()
			cur.flags |= set(val)
		else:
			# key:value pairs
			sep = ": " if ": " in line else "="
			try:
				key, val = line.split(sep, 1)
			except ValueError:
				print >> sys.stderr, "{%s} not in key=value format, ignored" % lineno
				return cur
			key, val = key.strip(), val.strip()
			key = self.fix_field_name(key)
			if val == "(none)" or val == "(null)":
				val = None
			try:
				cur[key].append(val)
			except KeyError:
				cur[key] = [val]
		return cur

	def parse(self, file):
		data, cur = [], Record()
		fh = open(file, "r")
		i = self.next_pos
		for lineno, line in enumerate(fh, start=1):
			line = line.strip()
			if not line:
				if len(cur) > 0:
					cur.pos, i = i, i+1
					data.append(cur)
				cur = Record()
			elif line.startswith("="):
				val = line[1:].strip()
				if len(cur) > 0:
					cur.pos, i = i, i+1
					data.append(cur)
				cur = Record()
				cur["Name"] = val
			elif line.startswith("("):
				pass
			else:
				cur = self.parse_line(line, cur, lineno)
		if len(cur) > 0:
			cur.pos, i = i, i+1
			data.append(cur)
		self.next_pos = i
		return data

	def sort(self):
		self.data.sort(key=lambda x: x["Name"].lower())
		self.modified = True

	def save(self):
		map(str, self.data) # make sure __str__() does not fail
		print "Writing database"
		with open(self.path, "w") as fh:
			self.dump(fh)
		self.modified = False

	def dump(self, fh=sys.stdout):
		for item in self.data:
			if "deleted" not in item.flags:
				print >> fh, item

	def dump_json(self, fh=sys.stdout):
		try:
			import json
		except ImportError:
			print >> sys.stderr, "Module 'json' not found."
		else:
			dbx = []
			for item in db.data:
				itemx = dict(item)
				if len(item.flags):
					itemx["flags"] = list(item.flags)
				dbx.append(itemx)
			print >> fh, json.dumps(dbx, indent=4)

	def dump_yaml(self, fh=sys.stdout):
		try:
			import yaml
		except ImportError:
			print >> sys.stderr, "Module 'yaml' not found."
		else:
			dbx = []
			for item in db.data:
				itemx = dict(item)
				if len(item.flags):
					itemx["flags"] = list(item.flags)
				dbx.append(itemx)
			print >> fh, yaml.dump(dbx)

	def close(self):
		if self.modified:
			self.save()

	def grep_named(self, pattern):
		if pattern.startswith("="):
			pattern = pattern[0]
			for item in self.data:
				if any(n==pattern for n in item.names()):
					yield item
		else:
			if "*" not in pattern:
				pattern += "*"
			for item in self.data:
				if fnmatch.filter(item.names(), pattern):
					yield item

	def grep_flagged(self, pattern, exact=True):
		if exact:
			test = lambda item, pat: pat.lower() in item.flags
		else:
			test = lambda item, pat: fnmatch.filter(item.flags, pat)

		for item in self.data:
			if test(item, pattern):
				yield item

	@classmethod
	def sort_fields(self, input, full=True):
		output = []
		for group in self.field_order:
			output += [k for k in self.fields[group] if k in input]
		if full:
			output += [k for k in input if k not in output]
		return output

	@classmethod
	def fix_field_name(self, name):
		name = name.lower()
		return {
			"h":			"host",
			"hostname":	"host",
			"machine":	"host",

			"@":		"uri",
			"url":		"uri",
			"website":	"uri",

			"l":			"login",
			"u":			"login",
			"user":		"login",
			"username":	"login",

			"p":			"pass",
			"password":	"pass",
		}.get(name, name)

class Interactive(Cmd):
	def __init__(self, *args, **kwargs):
		Cmd.__init__(self, *args, **kwargs)
		self.prompt = "accdb> "
		self.banner = "Using %s" % dbfile
		self._foo = False

	def emptyline(self):
		pass

	def default(self, line):
		print >> sys.stderr, "Are you on drugs?"

	def do_EOF(self, arg):
		"""Save changes and exit"""
		db.close()
		return True

	do_quit = do_EOF
	do_exit = do_EOF
	do_q = do_quit

	def do_write(self, arg):
		"""Write modified database to disk"""
		db.save()

	do_w = do_write

	def do_help(self, arg):
		if self._foo:
			for cmd in dir(self):
				if cmd.startswith("do_") and cmd not in ("do_help", "do_EOF", "do_xyzzy"):
					print "    %-14s %s" % (cmd[3:], getattr(self, cmd).__doc__ or "?")
		else:
			print "RTFM"
			self._foo = True
	
	def do_xyzzy(self, arg):
		print "Nothing happens."
		
	def do_info(self, arg):
		"""Database summary"""
		print "%d entries in %s" % (len(db.data), db.path)

	def do_ls(self, arg):
		"""List entries by name"""
		results = list(db.grep_named(arg) if arg else db.data)
		if results:
			pos_w = len(str(max(i.pos for i in results)))
			for item in results:
				if "deleted" in item.flags: continue
				name = item["Name"]
				try:
					login = (item[f] for f in db.fields["username"] if f in item).next()
					login = login[0]
				except StopIteration:
					login = ""
				print "%*s | %-*s%s" % (pos_w, item.pos, 40, name, login)

	def do_grep(self, arg):
		"""Search for an entry"""
		results = db.grep_named(arg) if arg else db.data
		num = 0
		for item in results:
			if "deleted" in item.flags: continue
			print "(item %s)" % item.pos
			print item
			num += 1
		print "(%d entr%s matching '%s')" % (num, ("y" if num == 1 else "ies"), arg)

	def do_flag(self, arg):
		"""Search for a flag"""
		exact = "*" not in arg
		results = db.grep_flagged(arg, exact)
		num = 0
		for item in results:
			if "deleted" in item.flags: continue
			print "(item %s)" % item.pos
			print item
			num += 1
		print "(%d entr%s matching '%s')" % (num, ("y" if num == 1 else "ies"), arg)

	def do_add(self, arg):
		"""Add a new entry"""
		rec = Record()
		rec.pos = db.next_pos
		rec["Name"] = raw_input("= ").strip()
		if not rec["Name"]:
			return
		while True:
			try:
				line = raw_input("\t").strip()
			except EOFError:
				line = None
			if not line:
				break
			else:
				rec = db.parse_line(line, rec)
		db.next_pos += 1
		db.data.append(rec)
		db.modified = True
		print "Added."
	
	def do_rm(self, arg):
		"""Remove an entry"""
		items = []
		for g in arg.split(","):
			if "-" in g:
				min, max = g.split("-", 1)
				items.extend(range(int(min), int(max)+1))
			else:
				items.append(int(g))
		
		for item in db.data:
			if item.pos in items:
				item.flag("deleted")
				items.remove(item.pos)
		db.modified = True

	def do_dump(self, arg):
		"""Dump database"""
		if not arg:
			db.dump()
		elif arg == "yaml":
			db.dump_yaml()
		elif arg == "json":
			db.dump_json()
		else:
			print >> sys.stderr, "Unsupported format %r" % arg

	def do_touch(self, arg):
		"""Mark database as modified"""
		db.modified = True

	def do_sort(self, arg):
		"""Sort database"""
		db.sort()

def run_editor(file):
	from subprocess import Popen
	Popen((os.environ.get("EDITOR", "notepad.exe"), file))

dbfile = os.environ.get("ACCDB", os.path.expanduser("~/accounts.db.txt"))
db = Database(dbfile)
interp = Interactive()

try:
	command = sys.argv[1].lower()
except IndexError:
	command = None

if command is None:
	interp.cmdloop()
elif command == "edit":
	run_editor(db.path)
else:
	interp._foo = True
	interp.onecmd(" ".join(sys.argv[1:]))

db.close()
