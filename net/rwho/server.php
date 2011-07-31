<?php
namespace RWho;

header("Content-Type: text/plain; charset=utf-8");

require __DIR__."/../config.php";
openlog("rwho-server", null, LOG_DAEMON);

function putlog($host, $msg) {
	$unsafe = "\000..\037";
	$host = addcslashes($host, $unsafe);
	$msg = "addr={$_SERVER["REMOTE_ADDR"]} host=$host $msg";
	if (USE_SYSLOG)
		syslog(LOG_INFO, $msg);
}

function update_host($db, $host) {
	$st = $db->prepare('INSERT INTO `hosts`
		(host, last_update, last_addr) VALUES (:host, :time, :addr)
		ON DUPLICATE KEY UPDATE last_update=:time, last_addr=:addr');
	$st->bindValue(":host", $host);
	$st->bindValue(":time", time());
	$st->bindValue(":addr", $_SERVER["REMOTE_ADDR"]);
	return $st->execute();
}

function delete_host($db, $host) {
	$st = $db->prepare('DELETE FROM `hosts` WHERE host=:host');
	$st->bindValue(":host", $host);
	return $st->execute();
}

function ut_insert($db, $host, $entry) {
	$st = $db->prepare('INSERT INTO `utmp`
		(host, user, uid, rhost, line, time, updated)
		VALUES (:host, :user, :uid, :rhost, :line, :time, :updated)');
	$st->bindValue(":host", $host);
	$st->bindValue(":user", $entry->user);
	$st->bindValue(":uid", $entry->uid);
	$st->bindValue(":rhost", $entry->host);
	$st->bindValue(":line", $entry->line);
	$st->bindValue(":time", $entry->time);
	$st->bindValue(":updated", time());
	return $st->execute();
}

function ut_delete($db, $host, $entry) {
	$st = $db->prepare('DELETE FROM `utmp` WHERE host=:host AND user=:user AND line=:line');
	$st->bindValue(":host", $host);
	$st->bindValue(":user", $entry->user);
	$st->bindValue(":line", $entry->line);
	//$st->bindValue(":time", $entry->time);
	return $st->execute();
}

function ut_delete_host($db, $host) {
	$st = $db->prepare('DELETE FROM utmp WHERE host=:host');
	$st->bindValue(":host", $host);
	return $st->execute();
}

$actions = array(
	"insert" => function() {
		global $host;

		$data = json_decode($_POST["utmp"]);
		if (!$data) {
			print "error: no data\n";
			return false;
		}

		$db = new \PDO(DB_PATH, DB_USER, DB_PASS);
		foreach ($data as $entry)
			ut_insert($db, $host, $entry);
		update_host($db, $host);
		print "OK\n";
	},

	"delete" => function() {
		global $host;

		$data = json_decode($_POST["utmp"]);
		if (!$data) {
			print "error: no data\n";
			return false;
		}

		$db = new \PDO(DB_PATH, DB_USER, DB_PASS);
		foreach ($data as $entry)
			ut_delete($db, $host, $entry);
		update_host($db, $host);
		print "OK\n";
	},

	"put" => function() {
		global $host;

		$data = json_decode($_POST["utmp"]);
		if ($data === false) {
			print "error: no data\n";
			return false;
		}

		$db = new \PDO(DB_PATH, DB_USER, DB_PASS);
		ut_delete_host($db, $host);
		foreach ($data as $entry)
			ut_insert($db, $host, $entry);
		update_host($db, $host);
		print "OK\n";
	},

	"destroy" => function() {
		global $host;

		$db = new \PDO(DB_PATH, DB_USER, DB_PASS);
		ut_delete_host($db, $host);
		delete_host($db, $host);
		print "OK\n";
	},
);

if (strlen($_POST["fqdn"]))
	$host = $_POST["fqdn"];
elseif (strlen($_POST["host"]))
	$host = $_POST["host"];
else
	die("Host not specified\n");

if (isset($_REQUEST["action"])) {
	$action = $_REQUEST["action"];
	if (isset($actions[$action])) {
		putlog($host, "action=$action data=".strlen($_POST["utmp"]));
		$actions[$action]();
	} else {
		die("Unknown action\n");
	}
} else {
	die("Action not specified\n");
}
