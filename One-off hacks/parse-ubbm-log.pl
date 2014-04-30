#!/usr/bin/env perl
no if $] >= 5.017011, warnings => qw(experimental::smartmatch);
use Nullroute::IRC;
use feature 'switch';
use POSIX qw(strftime);

sub int2time {
	my $int = shift // return "∞";

	$int = int($int / 1_000_000);
	$int -= my $s = $int % 60; $int /= 60;
	$int -= my $m = $int % 60; $int /= 60;
	$int -= my $h = $int % 24; $int /= 25;

	$h ? sprintf("%dh%02d:%02d", $h, $m, $s)
	   : sprintf("%d:%02d", $m, $s);
}

sub ts2time {
	strftime("%F %T %z", localtime(shift));
}

my ($my_nick, $my_host);

my $chan_re = qr/^#/;

my $ctcp_re = qr/^\x01(.+)\x01$/;

my %isupport = {
	CASEMAPPING => 'rfc1459',
};

sub nicklc {
	$str = lc shift;
	for ($isupport{CASEMAPPING}) {
		when ("ascii") { ; }
		when ("rfc1459") { $str =~ y/[\\]/{|}/; }
		when ("rfc2812") { $str =~ y/[\\]~/{|}^/; }
	}
	$str;
}

sub nickeq {
	nicklc(shift) eq nicklc(shift);
}

sub ischannel {
	my ($target) = @_;
	$target =~ $chan_re;
}

sub targetlc {
	my $target = shift;

	ischannel($target) ? lc($target) : nicklc($target);
}

my %chan2nicks;
my %nick2chans;
my %chan2fd;
my %lastevent;

sub user_joined {
	my $nick = nicklc(shift);
	my $chan = lc(shift);

	$nicks = ($chan2nicks{$chan} //= {});
	$chans = ($nick2chans{$nick} //= {});

	$nicks->{$nick} = 1;
	$chans->{$chan} = 1;
}

sub user_left {
	my $nick = nicklc(shift);
	my $chan = lc(shift);

	$nicks = ($chan2nicks{$chan} //= {});
	$chans = ($nick2chans{$nick} //= {});

	delete $nicks->{$nick};
	delete $chans->{$chan};
}

sub user_renamed {
	my $oldnick = nicklc(shift);
	my $newnick = nicklc(shift);

	$chans = $nick2chans{$oldnick} // {};
	for my $chan (keys %$chans) {
		user_left($oldnick, $chan);
		user_joined($newnick, $chan);
	}
	$nick2chans{$newnick} = $chans;
	delete $nick2chans{$oldnick};
}

sub user_destroyed {
	my $nick = nicklc(shift);

	$chans = $nick2chans{$nick};
	if ($chans) {
		for my $chan (keys %$chans) {
			user_left($nick, $chan);
		}
		delete $nick2chans{$nick};
	}
}

sub chan_destroyed {
	my $chan = lc(shift);

	$nicks = $chan2nicks{$chan};
	if ($nicks) {
		for my $nick (keys %$nicks) {
			user_left($nick, $chan);
		}
		delete $chan2nicks{$chan};
	}
}

sub all_info_destroyed {
	%chan2nicks = ();
	%nick2chans = ();
}

sub get_user_channels {
	my $nick = nicklc(shift);

	$chans = $nick2chans{$nick};
	if ($chans) {
		return keys %$chans;
	} else {
		return;
	}
}

sub channels_for {
	[get_user_channels(shift)];
}

sub log_to {
	my $target = shift;
	my $msg = shift;

	return unless $target eq '#clueirc';

	$xtarget = $target;
	$xtarget =~ s/[^#a-z0-9]/_/g;

	if (!$chan2fd{$target}) {
		open($chan2fd{$target}, ">", "ubbm-$xtarget.log");
	}

	print {$chan2fd{$target}} $msg;
}

while (<>) {
	($time, $line) = /^\[([\d, ]+)\](.+)$/o or next;
	@time = map {int} split(/, /, $time);
	$line =~ s/\r$//;
	@parv = Nullroute::IRC::split_line($line);
	$isotime = strftime("%F %T",
		$time[5],   $time[4],   $time[3],
		$time[2]-1, $time[1]-1, $time[0]-1900);
	my @todo;
	my $src;
	my $src_nick;
	my $src_host;
	if ($parv[0] =~ s/^://o) {
		$src = shift(@parv);
		($src_nick, $src_host) = split(/!/, $src, 2);
	} else {
		($src_nick, $src_host) = ($my_nick, $my_host);
	}
	my $cmd = uc shift(@parv);
	my $chan;
	my $out;
	my $log;
	for ($cmd) {
		when ("PING") { next; }
		when ("PONG") { next; }
		# numerics
		when ("001") {
			$my_server = $src;
			($my_nick, $str) = @parv;
			$out = "--- Misc $cmd: $str";
			@str = split(/ /, $str);
			(undef, $my_host) = split(/!/, pop(@str), 2);
		}
		when (["002", "003", "004", "470"]) {
			(undef, @str) = @parv;
			$out = "--- Misc $cmd: @str";
		}
		when ("005") {
			(undef, @str) = @parv;
			$out = "--- Misc $cmd: @str";
			pop @str;
			for my $token (@str) {
				if (/^(.+?)=(.*)$/) {
					$isupport{$1} = $2;
				} else {
					$isupport{$token} = 1;
				}
			}
		}
		when (["375", "372", "376", "422"]) {
			(undef, $str) = @parv;
			$out = "--- Motd: $str";
		}
		when ("412") {
			(undef, $str) = @parv;
			$out = "-!- Error: $str";
		}
		when (["401", "403", "421", "451", "461", "474"]) {
			(undef, $arg, $str) = @parv;
			$out = "-!- Error: $arg -- $str";
		}
		when ("404") {
			(undef, $arg, $str) = @parv;
			$out = "-!- Cannot send to $arg: $str";
		}
		when (["251", "252", "254", "255", "265", "266"]) {
			(undef, @str) = @parv;
			$str = join(" ", @str);
			$out = "--- Lusers: $str";
		}
		when ("311") {
			(undef, $nick, $user, $host, undef, $gecos) = @parv;
			$out = "--- Whois $nick: ($user\@$host) is $gecos";
		}
		when ("312") {
			(undef, $nick, $server, $sdesc) = @parv;
			$out = "--- Whois $nick: is connected to $server ($sdesc)";
		}
		when ("317") {
			(undef, $nick, $idle_s, $signon_ts, undef) = @parv;
			$signon_time = ts2time($signon_time);
			$idle = int2time($idle_s);
			$out = "--- Whois $nick: signed on $signon_time, idle for $idle";
		}
		when ("319") {
			(undef, $nick, $channels) = @parv;
			$out = "--- Whois $nick: is in $channels";
		}
		when (["318", "378"]) {
			(undef, $nick, $str) = @parv;
			$out = "--- Whois $nick: $str";
		}
		when ("366") { next; }
		# events
		when ("INVITE") {
			($victim, $chan) = @parv;
			$out = "-!- $src_nick invites $victim to $chan";
		}
		when ("JOIN") {
			($chan) = @parv;
			if (defined $src) {
				$out = "--> $src_nick ($src_host) has joined $chan";
				$log = $chan;
				if (nickeq($src_nick, $my_nick)) {
					chan_destroyed($chan);
					if ($lastevent{lc($chan)}) {
						$out .= " (left ".$lastevent{lc($chan)}.")";
					}
				}
				user_joined($src_nick, $chan);
			} else {
				$out = "-=- Trying to join $chan";
			}
		}
		when ("KICK") {
			($chan, $victim, $reason) = @parv;
			$out = "<-- $src has kicked $victim from $chan ($reason)";
			$log = $chan;
			user_left($victim, $chan);
		}
		when ("MODE") {
			($chan, $mode, @mode_args) = @parv;
			$mode = join(" ", $mode, @mode_args);
			$out = "-|- $src sets mode [$mode] on $chan";
			$log = $chan;
		}
		when ("NICK") {
			($new_nick) = @parv;
			if (!defined($src)) {
				$my_nick = $new_nick;
				next;
			}
			if (nickeq($src, $my_nick)) {
				$my_nick = $new_nick;
			}
			$out = "-|- $src_nick is now known as $new_nick";
			$log = channels_for($src_nick);
			user_renamed($src_nick, $new_nick);
		}
		when ("NOTICE") {
			($dst, $msg) = @parv;
			if ($msg =~ $ctcp_re) {
				$out = "[$src reply: $1]";
			} else {
				$out = "-$src- $msg";
			}
			$log = $dst;
		}
		when ("PART") {
			($chan, $reason) = @parv;
			if (defined $src) {
				$out = "<-- $src_nick ($src_host) has left $chan ($reason)";
				user_left($src_nick, $chan);
			} else {
				$out = "-=- Leaving $chan ($reason)";
				chan_destroyed($chan);
			}
			$log = $chan;
		}
		when ("PRIVMSG") {
			($dst, $msg) = @parv;
			# <FIXUP>
			if ($dst =~ / / && !length($msg)) {
				($dst, $msg) = Nullroute::IRC::split_line($dst);
			}
			# </FIXUP>
			if ($msg =~ /^\x01ACTION (.+?)\x01?$/) {
				$out = " * $src_nick $1";
			} elsif ($msg =~ $ctcp_re) {
				$out = "[$src_nick CTCP $1]";
			} else {
				$out = "<$src_nick> $msg";
			}
			$log = $dst;
		}
		when ("QUIT") {
			($reason) = @parv;
			if (defined $src) {
				$out = "<-- $src_nick ($src_host) has quit ($reason)";
				$log = channels_for($src_nick);
				user_destroyed($src_nick);
			} else {
				$out = "-=- Quitting ($reason)";
				all_info_destroyed();
			}
		}
		when ("TOPIC") {
			($chan, $topic) = @parv;
			$out = "-|- $src_nick has set topic of $chan to: $topic";
			$log = $chan;
		}
		when ("353") {
			(undef, undef, $chan, $nicks) = @parv;
			$out = "--- People in $chan: $nicks";
			$log = $chan;
			for my $nick (split(/ /, $nicks)) {
				user_joined($nick, $chan);
			}
		}
		when ("332") {
			(undef, $chan, $topic) = @parv;
			$out = "--- Topic for $chan: $topic";
			$log = $chan;
		}
		when ("333") {
			(undef, $chan, $setter, $topic_ts) = @parv;
			$topic_time = ts2time($topic_ts);
			$out = "--- Topic for $chan was set by $setter on $topic_time ($topic_ts)";
			$log = $chan;
		}
		# commands that can be only sent
		when ("USER") { next; }
		when ("WHOIS") {
			($victim) = @parv;
			$out = "=-= $cmd $victim";
		}
		# etc.
		when ("ERROR") {
			($str) = @parv;
			$out = "=!= Error: $str";
		}
		default {
			$out = "unhandled: $line";
		}
	}
	$log //= "(server)";

	my @logdests;

	if (ref $log eq 'ARRAY') {
		@logdests = @$log;
	} else {
		@logdests = ($log);
	}

	@logdests = map {targetlc($_)} @logdests;

	if (defined($out)) {
		for my $dest (@logdests) {
			log_to($dest, "$isotime | $out\n");
			$lastevent{$dest} = $isotime;
		}

		printf "%s | %-16s | %s\e[m\n", $isotime, join(",", @logdests), $out;
	}
}
