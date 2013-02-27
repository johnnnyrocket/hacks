#!/usr/bin/env perl
use warnings;
use strict;
use feature qw(say switch);
use English;
use File::Basename;
use File::stat;
use File::Temp qw(tempfile);

my $ccprefix;
my $cccurrent;
my $ccdefault;
my $cccdir;
my $cccprimary;
my @caches;

my $use_color;

sub uniq { my %seen; grep {!$seen{$_}++} @_; }

sub interval {
	my $end = shift;
	my $start = shift // time;
	my ($dif, $s, $m, $h, $d);

	$dif = $end - $start;
	$dif -= $s = $dif % 60; $dif /= 60;
	$dif -= $m = $dif % 60; $dif /= 60;
	$dif -= $h = $dif % 24; $dif /= 24;
	$d = $dif + 0;

	if ($d > 1)	{ "${d}d ${h}h" }
	elsif ($h > 0)	{ "${h}h ${m}m" }
	elsif ($m > 1)	{ "${m} mins" }
	elsif ($s > 45)	{ "a minute" }
	else		{ "${s} secs" }
}

sub enum_ccaches {
	my @ccaches;

	open(my $proc, "-|", "pklist", "-l", "-N")
		or die "'pklist' not found\n";
	push @ccaches, grep {chomp or 1} <$proc>;
	close($proc);

	# traditional

	push @ccaches,	map {"FILE:$_"}
			grep {
				my $st = stat($_);
				-f $_ && $st->uid == $UID
			}
			glob("/tmp/krb5cc*");

	# new

	if ($ENV{XDG_RUNTIME_DIR} && -d "$ENV{XDG_RUNTIME_DIR}/krb5cc") {
		push @ccaches,	map {"DIR::$_"}
				glob("$ENV{XDG_RUNTIME_DIR}/krb5cc/tkt*");
	}

	# Heimdal kcmd

	if (-S "/var/run/.heim_org.h5l.kcm-socket") {
		push @ccaches, "KCM:$UID";
	}

	# kernel keyrings

	my @keys = uniq map {split} grep {chomp or 1}
		   qx(keyctl rlist \@s 2>/dev/null),
		   qx(keyctl rlist \@u 2>/dev/null);
	for my $key (@keys) {
		# TODO: deshell
		chomp(my $desc = qx(keyctl rdescribe "$key"));
		if ($desc =~ /^keyring;.*?;.*?;.*?;(krb5cc\.*)$/) {
			push @ccaches, "KEYRING:$1";
		}
	}

	@ccaches = grep {system("pklist", "-q", "-c", $_) == 0}
			uniq sort @ccaches;

	my $have_current = ($cccurrent ~~ @ccaches);
	my $have_default = ($ccdefault ~~ @ccaches);
	if (!$have_current) {
		push @ccaches, $cccurrent;
	}

	return @ccaches;
}

sub expand_ccname {
	my ($name) = @_;
	for ($name) {
		when ("new") {
			my (undef, $path) = tempfile($ccprefix."XXXXXX", OPEN => 0);
			return "FILE:$path";
		}
		when (/^@?$/) {
			return $ccdefault;
		}
		when (/^kcm$/i) {
			return "KCM:$UID";
		}
		when (/^\d\d?$/) {
			# return $caches[i]
			...;
		}
		when (/^\^\^(.*)$/) {
			return "KEYRING:$1";
		}
		when (/^\^(.*)$/) {
			return "KEYRING:krb5cc.$1";
		}
		when (":") {
			return "DIR:$cccdir";
		}
		when (/^:(.+)$/) {
			return "DIR::$cccdir/tkt$1";
		}
		when (/:/) {
			return $_;
		}
		when (m|/|) {
			return "FILE:$_";
		}
		default {
			return "FILE:$ccprefix$_";
		}
	}
}

sub collapse_ccname {
	my ($name) = @_;
	for ($name) {
		when ($ccdefault) {
			return "@";
		}
		when (m|^DIR::\Q$cccdir\E/(tkt)?(.*)$|) {
			return ":$2";
		}
		when (m|^FILE:\Q$ccprefix\E(.*)$|) {
			return $1;
		}
		when (m|^FILE:(/.*)$|) {
			return $1;
		}
		#when ("API:$principal") {
		#	return "API:";
		#}
		when ("KCM:$UID") {
			return "KCM";
		}
		when (m|^KEYRING:krb5cc\.(.*)$|) {
			return "^$1";
		}
		when (m|^KEYRING:(.*)$|) {
			return "^^$1";
		}
		default {
			return $_;
		}
	}
}

sub cmp_ccnames {
	my ($a, $b) = @_;
	$a = "FILE:$a" unless $a =~ /:/;
	$b = "FILE:$b" unless $b =~ /:/;
	return $a eq $b;
}

$ccprefix = "/tmp/krb5cc_${UID}_";
chomp($cccurrent = qx(pklist -N));
chomp($ccdefault = qx(unset KRB5CCNAME; pklist -N));
$cccdir = "";
$cccprimary = "";
if (-d "$ENV{XDG_RUNTIME_DIR}/krb5cc") {
	$cccdir = "$ENV{XDG_RUNTIME_DIR}/krb5cc";
}
if ($cccurrent =~ m|^DIR::(.+)$|) {
	$cccdir = dirname($1);
	if (-f "$cccdir/primary") {
		# TODO: deshell
		chomp($cccprimary = qx(cat "$cccdir/primary"));
	} else {
		$cccprimary = "tkt";
	}
}
@caches = enum_ccaches();

$use_color = ($ENV{TERM} && -t 1);

my $cmd = shift @ARGV;

for ($cmd) {
	when (["-h", "--help"]) {
		say for
		"Usage: kc [list]",
		"       kc <name>|\"@\" [kinit_args]",
		"       kc <number>",
		"       kc purge",
		"       kc destroy <name|number>...";
	}
	when (undef) {
		my $i = 1;
		for my $ccname (@caches) {
			my $shortname;
			my $principal;
			my $ccrealm;
			my $expiry;
			my $tgt_expiry;
			my $init_service;
			my $init_expiry;

			my $expiry_str = "";
			my $expiry_color = "";
			my $item_flag = "";
			my $flag_color = "";
			my $name_color = "";
			my $princ_color = "";

			open(my $proc, "-|", "pklist", "-c", $ccname)
				or die "Please install 'pklist' to use this tool.\n";

			while (<$proc>) {
				chomp;
				my @l = split(/\t/, $_);
				given (shift @l) {
					when ("principal") {
						($principal) = @l;
						$principal =~ /.*@(.+)$/
							and $ccrealm = $1;
					}
					when ("ticket") {
						my ($t_client, $t_service, undef, $t_expiry, undef, $t_flags, undef) = @l;
						if ($t_service eq "krbtgt/$ccrealm\@$ccrealm") {
							$tgt_expiry = $t_expiry;
						}
						if ($t_flags =~ /I/) {
							$init_service = $t_service;
							$init_expiry = $t_expiry;
						}
					}
				}
			}
			close($proc);

			$shortname = collapse_ccname($ccname);

			$expiry = $tgt_expiry || $init_expiry;

			if ($expiry) {
				if ($expiry <= time) {
					$expiry_str = "(expired)";
					$expiry_color = "31";
					$item_flag = "×";
					$flag_color = "31";
				} else {
					$expiry_str = interval($expiry);
					$expiry_color = ($expiry > time + 1200) ? "" : "33";
				}
			}

			if ($ccname eq $cccurrent) {
				$item_flag = ($ccname eq $ENV{KRB5CCNAME}) ? "»" : "*";
				$flag_color = ($expiry <= time) ? "1;31" : "1;32";
				$name_color = $flag_color;
				$princ_color = $name_color;
			}

			printf "\e[%sm%1s\e[m %2d ", $flag_color, $item_flag, $i;
			printf "\e[%sm%-15s\e[m", $name_color, $shortname;
			if (length $shortname > 15) {
				printf "\n%20s", "";
			}
			printf " \e[%sm%-40s\e[m", $princ_color, $principal;
			printf " \e[%sm%s\e[m", $expiry_color, $expiry_str;
			print "\n";
			++$i;
		}
		if ($i == 1) {
			say "No Kerberos credential caches found.";
			exit 1;
		}
	}
	when ("purge") {
		for my $ccname (@caches) {
			chomp(my $principal = qx(pklist -c "$ccname" -P));
			say "Renewing credentials for $principal in $ccname";
			system("kinit", "-c", $ccname, "-R") == 0
				|| system("kdestroy", "-c", $ccname);
		}
	}
	when ("destroy") {
		...
	}
	when ("clean") {
		...
	}
	when ("expand") {
		say expand_ccname($_) for @ARGV;
	}
	when ("list") {
		say for @caches;
	}
	when ("slist") {
		say collapse_ccname($_) for @caches;
	}
	when (/^=(.*)$/) {
		...
	}
	when (/.+@.+/) {
		...
	}
	default {
		...
	}
}
