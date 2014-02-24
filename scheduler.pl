#!/usr/bin/perl

# Author		: Jeremy Guan <jeremy.guan@gmail.com>
# Description	: Scheduling tool for MVCP to manage recordings
# Date			: 2011/08/07 18:35:07

use strict;
use warnings;

use POE qw( Component::Server::TCP Component::Client::TCP Component::JobQueue );
use Data::Dumper;

# validate number of arguments
if ($#ARGV != 1) {
	print "Usage: scheduler.pl FILE PORT\n";
	exit;
# validate port number
} elsif ($ARGV[1] !~ /^\d+$/ || $ARGV[1] > 65536) {
	print "Error: PORT should be between 0 and 65536\n";
	print "Usage: scheduler.pl FILE PORT\n";
	exit;
} 

my @SERVERS;
my $PORT = $ARGV[1];
my %CLIENTS;
my $LOG_FILE = 'scheduler.log';

# read the description file
open(FILE, $ARGV[0]) or die("Error: cannot open file '$ARGV[0]': $!\n");
while (<FILE>) {
	chomp;
	my @fields = split(/\s+/);
	push @SERVERS, { name => $fields[0], ip => $fields[1], port => $fields[2] };
}
close FILE;

# POE::Component::JobQueue handles the job queue against priority
POE::Component::JobQueue->spawn (
	Alias => 'passive_queuer',
	Worker 	=> \&spawn_worker,
	Passive => { Prioritizer => \&job_comparer },
	WorkerLimit => 1, # make sure video server takes 1 job at a time
);

# re-order job queue against priority
sub job_comparer {
	my ($first_job, $second_job) = @_;
	return $first_job->[1]{priority} <=>$second_job->[0]{priority};
}

# spawn new client session whenever job needs to be performed
sub spawn_worker {
	my ($postback, $job) = @_;
	my $ip = $job->{ip};
	my $port = $job->{port};
	POE::Component::Client::TCP->new(
		Args => [ $postback, $job ],
		RemoteAddress => $ip,
		RemotePort => $port,
		Started => sub {
			my $heap = $_[ HEAP ];
			$heap->{postback} = $postback;
			$heap->{job} = $job;
			sys_log("client session has been started for video server $heap->{job}{ip}:$heap->{job}{port}");
		},
		Connected => sub {
			my $heap = $_[ HEAP ];
			$heap->{stage} = 0;
			sys_log("client session connected to video server $heap->{job}{ip}:$heap->{job}{port}");
		},
		Disconnected => sub {
			my $heap = $_[ HEAP ];
			sys_log("client session disconnected from video server $heap->{job}{ip}:$heap->{job}{port}");
		},
		ConnectError => sub {
			my $heap = $_[ HEAP ];
			sys_log("client session could not connect to video searver $heap->{job}{ip}:$heap->{job}{port}");
			my $postback = delete $heap->{postback};
			$postback->("client session could not connect to video searver $heap->{job}{ip}:$heap->{job}{port}");
		},
		ServerError => sub {
			my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];
			sys_log("video server $heap->{job}{ip}:$heap->{job}{port} has encountered error");
			my $postback = delete $heap->{postback};
			$postback->("video server $heap->{job}{ip}:$heap->{job}{port} has encountered error");
		},
		ServerInput => sub {
			my ( $kernel, $heap, $input ) = @_[ KERNEL, HEAP, ARG0 ];
			if (defined($input)) {
				sys_log("video server $heap->{job}{ip}:$heap->{job}{port}: '$input'");
				my $file = $heap->{job}{file};
				my $time = $heap->{job}{time};
				if ($heap->{stage} == 0) {
					$heap->{stage}++;
					$kernel->yield("send_server", "UADD 10101");
				} elsif ($heap->{stage} == 1 && $input =~ /^U\d+$/) {
					$heap->{stage}++;
					$heap->{unit} = $input;
					$kernel->yield("send_server", "LOAD $input $file");
				} elsif ($heap->{stage} == 2 && $input =~ /^$file/) {
					$heap->{stage}++;
					my $unit = $heap->{unit};
					$kernel->yield("send_server", "CUER $unit");
				} elsif ($heap->{stage} == 3) {
					$heap->{stage}++;
					my $unit = $heap->{unit};
					$kernel->yield("send_server", "REC $unit");
				} elsif ($heap->{stage} == 4) {
					$heap->{stage}++;
					my $unit = $heap->{unit};
					$kernel->delay(send_server => $time, "STOP $unit");
				} elsif ($heap->{stage} == 5) {
					$heap->{stage}++;
					my $unit = $heap->{unit};
					$kernel->yield("send_server", "UNLD $unit");
				} elsif ($heap->{stage} == 6) {
					$heap->{stage}++;
					my $unit = $heap->{unit};
					$kernel->yield("send_server", "UCLS $unit");
				} elsif ($heap->{stage} > 6) {
					$kernel->yield('shutdown');
					my $postback = delete $heap->{postback};
					$postback->("The file '$file' on video server $heap->{job}{ip}:$heap->{job}{port} is recorded");
				} elsif ($heap->{stage} == 1 || $input eq '200 OK' || $input eq '201 OK' || $input eq '202 OK') {
					# initial stage or successful acknowledge message, no action needed
				} else {
					$kernel->yield('shutdown');
					my $postback = delete $heap->{postback};
					$postback->("The recording of the file '$file' on video server $heap->{job}{ip}:$heap->{job}{port} is failed. ERROR: '$input'");
				}
			}
		},
		InlineStates => {             
			send_server => sub {
				my ( $heap, $message ) = @_[ HEAP, ARG0 ];
				$heap->{server}->put($message);
				sys_log("client session sent to video server $heap->{job}{ip}:$heap->{job}{port}: '$message'");
			},
		},
	);
}

# POE::Component::Server::TCP is the listener to pass user's cmd to video server
# and notify user when job is done
POE::Component::Server::TCP->new(
	Port => $PORT,
	InlineStates => {
		postback => sub {
			my ( $heap, $request, $response ) = @_[ HEAP, ARG0, ARG1 ];
			$heap->{client}->put($response->[0]);
		},
	},
	ClientConnected => \&client_connected,
	ClientDisconnected => \&client_disconnected,
	ClientInput => \&client_input,
);

sub client_connected {
	my ( $kernel, $session, $heap ) = @_[ KERNEL, SESSION, HEAP ];
	my $session_id = $session->ID;
	if (scalar(keys %CLIENTS) > 0) {
		sys_log("Session[$session_id] connection is existing! ignoring new connection");
		$kernel->yield('shutdown');
		return;
	}
	$CLIENTS{$session_id} = 1;
	sys_log("Session[$session_id] connected. Total clients: " . scalar(keys %CLIENTS));
}

sub client_disconnected {
	my ( $kernel, $session, $heap ) = @_[ KERNEL, SESSION, HEAP ];
	my $session_id = $session->ID;
	delete $CLIENTS{$session_id};
	sys_log("Session[$session_id] disconnected. Total clients: " . scalar(keys %CLIENTS));
}

sub client_input {
	my ($kernel, $session, $heap, $input) = @_[KERNEL, SESSION, HEAP, ARG0];
	my $session_id = $session->ID;
	sys_log("Session[$session_id] input: $input");

	my ($cmd, $priority, $server, $file, $time) = split(/\s+/, $input);
	if ($cmd && defined $priority && $server && $file && defined $time && $cmd =~ /^RECORD$/i) {
		if ($priority !~ /^\d+$/ || $priority > 100) {
			$heap->{client}->put("Error: priority should be between 0 and 100");
			$heap->{client}->put("Usage: RECORD priority server filename time");
			return;
		} elsif ($time !~ /^\d+$/) {
			$heap->{client}->put("Error: time is the length of the recording (in seconds)");
			$heap->{client}->put("Usage: RECORD priority server filename time");
			return;
		}
		my ($ip, $port);	
		for (@SERVERS) {
			if ($_->{name} =~ /^$server$/i) {
				$ip = $_->{ip};
				$port = $_->{port};
				my $job = { priority => $priority, ip => $ip, port => $port, file => $file, time => $time };
				$kernel->post( 'passive_queuer', 'enqueue', 'postback', $job );
				last;
			} 
		}
		$heap->{client}->put("Error: Video server '$server' not found") unless ($ip && $port);
	} else {
		$heap->{client}->put("Usage: RECORD priority server filename time");
	}
}

POE::Kernel->run();
exit;

sub sys_log {
	my $msg = shift;
	my $log = $LOG_FILE;
	my ($sec, $min, $hr, $day, $mon, $year) = localtime(time);
	my $ts = sprintf("%04d%02d%02d %02d:%02d:%02d", 1900 + $year, $mon + 1, $day, $hr, $min, $sec);
	open LOG, ">>$log" or die "Error: cannot open log file '$log': $!\n";
	print LOG "$ts $msg\n";
	print "$ts $msg\n";
	close LOG;
}

