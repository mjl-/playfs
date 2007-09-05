implement Playfs;

include "sys.m";
include "draw.m";
include "arg.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "string.m";
include "styx.m";
	Tmsg, Rmsg: import Styx;
include "styxservers.m";
include "rand.m";
include "daytime.m";
include "sh.m";

sys: Sys;
str: String;
styx: Styx;
styxservers: Styxservers;
daytime: Daytime;
sh: Sh;
rand: Rand;

sprint: import sys;
Styxserver, Fid, Navigator, Navop: import styxservers;

Enotfound, Enotdir: import Styxservers;

Dflag, dflag: int;

Qroot, Qctl, Qstatus, Qevents, Qlist, Qorderlist, Qoffset, Qmax: con iota;
tab := array[] of {
	(Qroot,		".",		Sys->DMDIR|8r555),
	(Qctl,		"ctl",		8r222),
	(Qstatus,	"status",	8r444),
	(Qevents,	"events",	8r444),
	(Qlist,		"list",		8r666),
	(Qorderlist,	"orderlist",	8r444),
	(Qoffset,	"offset",	8r444),
};

Playing, Started, Paused, Stopped: con iota;	# state
states := array[] of {"started", "playing", "paused", "stopped"};

srv: ref Styxserver;

pid := -1;
donech: chan of (string, string);
state := Stopped;
playlist := array[0] of string;
order := array[0] of int;
playoff: int;
repeat, random: int;
mtime: int;

File: adt {
	fid:	int;
	data:	array of byte;
	reads:	array of ref Tmsg.Read;

	new:		fn(fid: int): ref File;
        putdata:	fn(f: self ref File, s: string);
        putread:	fn(f: self ref File, m: ref Tmsg.Read);
        styxop:		fn(f: self ref File): ref Rmsg.Read;
        flushop:	fn(f: self ref File, tag: int): int;
};
eventfiles := array[0] of ref File;


Playfs: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	bufio = load Bufio Bufio->PATH;
	str = load String String->PATH;
	styx = load Styx Styx->PATH;
	styx->init();
	styxservers = load Styxservers Styxservers->PATH;
	styxservers->init(styx);
	daytime = load Daytime Daytime->PATH;
	rand = load Rand Rand->PATH;
	rand->init(sys->millisec());
	sh = load Sh Sh->PATH;

	arg->init(args);
	arg->setusage(arg->progname()+" [-Dd]");
	while((c := arg->opt()) != 0)
		case c {
		'D' =>	Dflag++;
			styxservers->traceset(Dflag);
		'd' =>	dflag++;
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 0)
		arg->usage();

	mtime = daytime->now();

	navch := chan of ref Navop;
	spawn navigator(navch);

	nav := Navigator.new(navch);
	msgc: chan of ref Tmsg;
	(msgc, srv) = Styxserver.new(sys->fildes(0), nav, big Qroot);

	donech = chan of (string, string);

done:
	for(;;) alt {
	(path, err) := <-donech =>
		say(sprint("done, path=%q err=%q", path, err));
		if(pid >= 0)
			killgrp(pid);
		pid = -1;
		if(err != nil)
			filewrite(eventfiles, "played "+path);
		else
			filewrite(eventfiles, sprint("error %q %q", path, err));
		if(state == Playing) {
			if(len playlist > 0 && (repeat || playoff < len playlist-1)) {
				say("spawning new player");
				playoff = (playoff+1)%len playlist;
				start();
			} else if(state == Playing) {
				say("no more files to play, going into started mode");
				state = Started;
				filewrite(eventfiles, "done");
			}
		}

	gm := <-msgc =>
		if(gm == nil)
			break;
		pick m := gm {
		Readerror =>
			warn("read error: "+m.error);
			break done;
		}
		dostyx(gm);
	}
}


clearlist()
{
	mtime = daytime->now();
	playlist = array[0] of string;
	order = array[0] of int;
	playoff = 0;
	stop();
	if(state == Playing)
		state = Started;
	else if(state == Paused)
		state = Stopped;
}

add[T](a: array of T, aa: array of T): array of T
{
	na := array[len a+len aa] of T;
	na[:] = a;
	na[len a:] = aa;
	return na;
}

addints(a: array of int, aa: array of int): array of int
{
	na := array[len a+len aa] of int;
	na[:] = a;
	na[len a:] = aa;
	return na;
}

randomize(a: array of int)
{
	for(i := 0; i < len a; i++) {
		r := rand->rand(len a);
		tmp := a[i];
		a[i] = a[r];
		a[r] = tmp;
	}
}

writelist(d: array of byte)
{
	(nil, l) := sys->tokenize(string d, "\n");
	a := array[len l] of string;
	o := array[len l] of int;
	i := 0;
	for(; l != nil; l = tl l)
		a[i++] = hd l;
	for(i = 0; i < len o; i++)
		o[i] = len order+i;
	playlist = add(playlist, a);
	order = addints(order, o);
	if(random)
		randomize(order[playoff:]);
	else
		for(j := playoff; j < len order; j++)
			order[j] = j;
	mtime = daytime->now();
}

cached := array[0] of byte;
cachetime := 0;
ocached := array[0] of byte;
ocachetime := 0;

listdata(): array of byte
{
	if(cachetime == 0 || cachetime <= mtime) {
		new := "";
		for(i := 0; i < len playlist; i++)
			new += playlist[i]+"\n";
		cached = array of byte new;
		cachetime = daytime->now();
	}
	return cached;
	
}

orderlistdata(): array of byte
{
	if(ocachetime == 0 || ocachetime <= mtime) {
		new := "";
		for(i := 0; i < len playlist; i++)
			new += playlist[order[i]]+"\n";
		ocached = array of byte new;
		ocachetime = daytime->now();
	}
	return ocached;
}

stop()
{
	if(pid >= 0)
		killgrp(pid);
	pid = -1;
}

start(): int
{
	if(len playlist > 0) {
		state = Playing;
		filewrite(eventfiles, status());
		spawn player(pidch := chan of int, playlist[order[playoff]]);
		pid = <-pidch;
		return 1;
	}
	return 0;
}

status(): string
{
	s := states[state];
	if(state == Playing)
		s += " "+playlist[order[playoff]];
	return s;
}

player(pidch: chan of int, path: string)
{
	sys->pctl(Sys->NEWPGRP|Sys->FORKFD, nil);
	pidch <-= sys->pctl(0, nil);
	err := sh->run(nil, "play"::path::nil);
	if(err != nil)
		say("play error: "+err);
	donech <-= (path, err);
}

ctl(m: ref Tmsg.Write)
{
	for((nil, l) := sys->tokenize(string m.data, "\n"); l != nil; l = tl l)
		case hd l {
		"next" =>
			playoff = (playoff+1)%len playlist;
			if(state == Playing) {
				stop();
				start();
			}
		"previous" =>
			playoff = (playoff-1+len playlist)%len playlist;
			if(state == Playing) {
				stop();
				start();
			}
		"stop" =>
			stop();
			if(state != Stopped) {
				state = Stopped;
				filewrite(eventfiles, status());
			}
		"play" =>
			if(state != Playing && state != Started) {
				state = Started;
				filewrite(eventfiles, status());
				start();
			}
		"pause" =>
			state = Paused;
			# xxx
		"random" =>
			random = 1;
			randomize(order[playoff:]);
		"norandom" =>
			if(len playlist > 0)
				playoff = order[playoff];
			for(i := 0; i < len order; i++)
				order[i] = i;
			random = 0;
		"repeat" =>
			repeat = 1;
		"norepeat" =>
			repeat = 0;
		"rewind" =>
			playoff = 0;
		"clear" =>
			clearlist();
		* =>
			(nil, tokens) := sys->tokenize(hd l, " ");
			if(len tokens == 3)
				case hd tokens {
				"bind" =>
					if(sys->bind(hd tl tokens, hd tl tl tokens, Sys->MREPL) < 0) {
						srv.reply(ref Rmsg.Error(m.tag, sprint("bind failed: %r")));
						return;
					}
					continue;
				}
			srv.reply(ref Rmsg.Error(m.tag, "bad command: "+hd l));
			return;
		}
	srv.reply(ref Rmsg.Write(m.tag, len m.data));
}

dostyx(gm: ref Tmsg)
{
	pick m := gm {
	Open =>
		(f, nil, nil, nil) := srv.canopen(m);
		if(f != nil && m.mode & Sys->OTRUNC && int f.path == Qlist) {
			if(state == Playing) {
				stop();
				state = Started;
			}
			clearlist();
		}
		if(f != nil && int f.path == Qevents) {
			eventfiles = add(eventfiles, array[] of {file := File.new(f.fid)});
			file.putdata(status());
		}
		srv.default(m);

	Write =>
		(f, err) := srv.canwrite(m);
		if(f == nil)
			return replyerror(m, err);
		case int f.path {
		Qctl =>
			ctl(m);
		Qlist =>
			writelist(m.data);
			if(len playlist > 0 && state == Started)
				start();
			srv.reply(ref Rmsg.Write(m.tag, len m.data));
		* =>
			srv.default(m);
		}

	Read =>
		f := srv.getfid(m.fid);
		if(f.qtype & Sys->QTDIR) {
			srv.default(m);
			return;
		}
		say(sprint("read f.path=%bd", f.path));
		case int f.path {
		Qstatus =>
			srv.reply(styxservers->readstr(m, status()));
		Qlist =>
			srv.reply(styxservers->readbytes(m, listdata()));
		Qorderlist =>
			srv.reply(styxservers->readbytes(m, orderlistdata()));
		Qevents =>
			fileread(eventfiles, m);
		Qoffset =>
			srv.reply(styxservers->readstr(m, string playoff));
		* =>
			srv.default(m);
		}

	Flush =>
		fileflush(eventfiles, m.tag);

	Clunk or Remove =>
		fileremove(eventfiles, m.fid);
		srv.default(m);

	* =>
		srv.default(gm);
	}
}

navigator(c: chan of ref Navop)
{
again:
	for(;;) {
		navop := <-c;
		say(sprint("have navop, tag %d", tagof navop));
		pick op := navop {
		Stat =>
			op.reply <-= (dir(int op.path), nil);

		Walk =>
			if(op.name == "..") {
				op.reply <-= (dir(Qroot), nil);
				continue again;
			}
			case int op.path&16rff {
			Qroot =>
				for(i := Qctl; i < Qmax; i++)
					if(tab[i].t1 == op.name) {
						op.reply <-= (dir(tab[i].t0), nil);
						continue again;
					}
				op.reply <-= (nil, Enotfound);
			* =>
				op.reply <-= (nil, Enotdir);
			}
		Readdir =>
			for(i := 0; i < op.count && i+op.offset < len tab-1; i++)
				op.reply <-= (dir(Qroot+1+i+op.offset), nil);
			op.reply <-= (nil, nil);
		}
	}
}

dir(path: int): ref Sys->Dir
{
	(nil, name, perm) := tab[path&16rff];
	d := ref sys->zerodir;
	d.name = name;
	d.uid = d.gid = "playfs";
	d.qid.path = big path;
	if(perm&Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	else
		d.qid.qtype = Sys->QTFILE;
	d.mtime = d.atime = mtime;
	d.mode = perm;
	if(path == Qlist)
		d.length = big len listdata();
	else if(path == Qorderlist)
		d.length = big len orderlistdata();
	return d;
}

replyerror(m: ref Tmsg, s: string)
{
	srv.reply(ref Rmsg.Error(m.tag, s));
}

File.new(fid: int): ref File
{
	return ref File(fid, array[0] of byte, array[0] of ref Tmsg.Read);
}

File.putdata(f: self ref File, s: string)
{
	sd := array of byte (s+"\n");
	nd := array[len f.data+len sd] of byte;
	nd[:] = f.data;
	nd[len f.data:] = sd;
	f.data = nd;
}

File.putread(f: self ref File, m: ref Tmsg.Read)
{
	f.reads = add(f.reads, array[] of {m});
}

File.styxop(f: self ref File): ref Rmsg.Read
{
	if(len f.data == 0 || len f.reads == 0)
		return nil;
	m := f.reads[0];
	f.reads = f.reads[1:];
	take := m.count;
	if(take > len f.data)
		take = len f.data;
	d := array[take] of byte;
	d[:] = f.data[:take];
	f.data = f.data[take:];
	return ref Rmsg.Read(m.tag, d);
}

File.flushop(f: self ref File, tag: int): int
{
	for(i := 0; i < len f.reads; i++)
		if(f.reads[i].tag == tag) {
			f.reads[i:] = f.reads[i+1:];
			f.reads = f.reads[:len f.reads-1];
			return 1;
		}
	return 0;
}

filewrite(f: array of ref File, s: string)
{
	for(i := 0; i < len f; i++)
		f[i].putdata(s);
	for(i = 0; i < len f; i++)
		while((op := f[i].styxop()) != nil)
			srv.reply(op);
}

fileread(f: array of ref File, m: ref Tmsg.Read)
{
	for(i := 0; i < len f; i++)
		if(f[i].fid == m.fid) {
			f[i].putread(m);
			while((op := f[i].styxop()) != nil)
				srv.reply(op);
			return;
		}
}

fileflush(f: array of ref File, tag: int)
{
	for(i := 0; i < len f; i++)
		if(f[i].flushop(tag))
			return;
}

fileremove(f: array of ref File, fid: int)
{
	for(i := 0; i < len f; i++)
		if(f[i].fid == fid) {
			f[i] = f[len f-1];
			f = f[:len f-1];
			return;
		}
}

killgrp(pid: int)
{
	fd := sys->open(sprint("/prog/%d/ctl", pid), Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "killgrp");
}

warn(s: string)
{
	sys->fprint(sys->fildes(2), "%s\n", s);
}

say(s: string)
{
	if(dflag)
		sys->fprint(sys->fildes(2), "%s\n", s);
}
