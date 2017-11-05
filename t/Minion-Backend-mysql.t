use Mojo::Base -strict;

BEGIN { $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll' }

use Test::More;

use Test::mysqld;
use Minion;
use Mojo::IOLoop;
use Sys::Hostname 'hostname';
use Time::HiRes qw(time usleep);

my $mysqld = Test::mysqld->new(
  my_cnf => {
    'skip-networking' => '', # no TCP socket
  }
) or plan skip_all => $Test::mysqld::errstr;

chomp( my $mysqld_version_info = qx{$mysqld->{mysqld} --version} );
diag "Running tests with MySQL/MariaDB server version: ";
diag $mysqld_version_info;

# Clean up before start
require Mojo::mysql;
my $mysql = Mojo::mysql->new( dsn => $mysqld->dsn( dbname => 'test' ));
$mysql->db->query('drop table if exists mojo_migrations');
$mysql->db->query('drop table if exists minion_jobs');
$mysql->db->query('drop table if exists minion_workers');
my $minion = Minion->new(mysql => dsn => $mysqld->dsn( dbname => 'test' ));
$minion->reset;

# Nothing to repair
my $worker = $minion->repair->worker;
isa_ok $worker->minion->app, 'Mojolicious', 'has default application';

# Register and unregister
$worker->register;
like $worker->info->{started}, qr/^[\d.]+$/, 'has timestamp';
my $notified = $worker->info->{notified};
like $notified, qr/^[\d.]+$/, 'has timestamp';
my $id = $worker->id;
is $worker->register->id, $id, 'same id';
usleep 50000;
cmp_ok $worker->register->info->{notified}, '>=', $notified, 'new timestamp';
is $worker->unregister->info, undef, 'no information';
my $host = hostname;
is $worker->register->info->{host}, $host, 'right host';
is $worker->info->{pid}, $$, 'right pid';
is $worker->unregister->info, undef, 'no information';

# Repair missing worker
$minion->add_task(test => sub { });
my $worker2 = $minion->worker->register;
isnt $worker2->id, $worker->id, 'new id';
$id = $minion->enqueue('test');
my $job = $worker2->dequeue(0);
is $job->id, $id, 'right id';
is $worker2->info->{jobs}[0], $job->id, 'right id';
$id = $worker2->id;
undef $worker2;
is $job->info->{state}, 'active', 'job is still active';
ok !!$minion->backend->worker_info($id), 'is registered';
$minion->backend->mysql->db->query(
  "update minion_workers
   set notified = DATE_SUB(now(), interval ? second) where id = ?",
  $minion->missing_after + 1, $id
);
$minion->repair;
ok !$minion->backend->worker_info($id), 'not registered';
like $job->info->{finished}, qr/^[\d.]+$/,       'has finished timestamp';
is $job->info->{state},      'failed',           'job is no longer active';
is $job->info->{result},     'Worker went away', 'right result';

# Repair abandoned job
$worker->register;
$id  = $minion->enqueue('test');
$job = $worker->dequeue(0);
is $job->id, $id, 'right id';
$worker->unregister;
$minion->repair;
is $job->info->{state},  'failed',           'job is no longer active';
is $job->info->{result}, 'Worker went away', 'right result';

# Repair old jobs
$worker->register;
$id = $minion->enqueue('test');
my $id2 = $minion->enqueue('test');
my $id3 = $minion->enqueue('test');
$worker->dequeue(0)->perform for 1 .. 3;
my $finished = $minion->backend->mysql->db->query(
  'select UNIX_TIMESTAMP(finished) as finished
   from minion_jobs
   where id = ?', $id2
)->hash->{finished};
$minion->backend->mysql->db->query(
  'update minion_jobs set finished = FROM_UNIXTIME(?) where id = ?',
  $finished - ($minion->remove_after + 1), $id2);
$finished = $minion->backend->mysql->db->query(
  'select UNIX_TIMESTAMP(finished) as finished
   from minion_jobs
   where id = ?', $id3
)->hash->{finished};
$minion->backend->mysql->db->query(
  'update minion_jobs set finished = FROM_UNIXTIME(?) where id = ?',
  $finished - ($minion->remove_after + 1), $id3);
$worker->unregister;
$minion->repair;
ok $minion->job($id), 'job has not been cleaned up';
ok !$minion->job($id2), 'job has been cleaned up';
ok !$minion->job($id3), 'job has been cleaned up';

# List workers
$worker  = $minion->worker->register;
$worker2 = $minion->worker->register;
my $batch = $minion->backend->list_workers(0, 10);
ok $batch->[0]{id},        'has id';
is $batch->[0]{host},      $host, 'right host';
is $batch->[0]{pid},       $$, 'right pid';
like $batch->[0]{started}, qr/^[\d.]+$/, 'has timestamp';
is $batch->[1]{host},      $host, 'right host';
is $batch->[1]{pid},       $$, 'right pid';
ok !$batch->[2], 'no more results';
$batch = $minion->backend->list_workers(0, 1);
is $batch->[0]{id}, $worker2->id, 'right id';
ok !$batch->[1], 'no more results';
$batch = $minion->backend->list_workers(1, 1);
is $batch->[0]{id}, $worker->id, 'right id';
ok !$batch->[1], 'no more results';
$worker->unregister;
$worker2->unregister;

# Reset
$minion->reset->repair;
ok !$minion->backend->mysql->db->query(
  'select count(id) as count from minion_jobs')->hash->{count}, 'no jobs';
ok !$minion->backend->mysql->db->query(
  'select count(id) as count from minion_workers')->hash->{count}, 'no workers';

# Wait for job
my $before = time;
$worker = $minion->worker->register;
is $worker->dequeue(0.5), undef, 'no jobs yet';
ok !!(($before + 0.5) <= time), 'waited for jobs';
$worker->unregister;

# Stats
$minion->add_task(
  add => sub {
    my ($job, $first, $second) = @_;
    $job->finish({added => $first + $second});
  }
);
$minion->add_task(fail => sub { die "Intentional failure!\n" });
my $stats = $minion->stats;
is $stats->{active_workers},   0, 'no active workers';
is $stats->{inactive_workers}, 0, 'no inactive workers';
is $stats->{active_jobs},      0, 'no active jobs';
is $stats->{failed_jobs},      0, 'no failed jobs';
is $stats->{finished_jobs},    0, 'no finished jobs';
is $stats->{inactive_jobs},    0, 'no inactive jobs';
$worker = $minion->worker->register;
is $minion->stats->{inactive_workers}, 1, 'one inactive worker';
$minion->enqueue('fail');
$minion->enqueue('fail');
is $minion->stats->{inactive_jobs}, 2, 'two inactive jobs';
$job   = $worker->dequeue(0);
$stats = $minion->stats;
is $stats->{active_workers}, 1, 'one active worker';
is $stats->{active_jobs},    1, 'one active job';
is $stats->{inactive_jobs},  1, 'one inactive job';
$minion->enqueue('fail');
my $job2 = $worker->dequeue(0);
$stats = $minion->stats;
is $stats->{active_workers}, 1, 'one active worker';
is $stats->{active_jobs},    2, 'two active jobs';
is $stats->{inactive_jobs},  1, 'one inactive job';
ok $job2->finish, 'job finished';
ok $job->finish,  'job finished';
is $minion->stats->{finished_jobs}, 2, 'two finished jobs';
$job = $worker->dequeue(0);
ok $job->fail, 'job failed';
is $minion->stats->{failed_jobs}, 1, 'one failed job';
ok $job->retry, 'job retried';
is $minion->stats->{failed_jobs}, 0, 'no failed jobs';
ok $worker->dequeue(0)->finish(['works']), 'job finished';
$worker->unregister;
$stats = $minion->stats;
is $stats->{active_workers},   0, 'no active workers';
is $stats->{inactive_workers}, 0, 'no inactive workers';
is $stats->{active_jobs},      0, 'no active jobs';
is $stats->{failed_jobs},      0, 'no failed jobs';
is $stats->{finished_jobs},    3, 'three finished jobs';
is $stats->{inactive_jobs},    0, 'no inactive jobs';

# List jobs
$id = $minion->enqueue('add');
$batch = $minion->backend->list_jobs(0, 10);
ok $batch->[0]{id},        'has id';
is $batch->[0]{task},      'add', 'right task';
is $batch->[0]{state},     'inactive', 'right state';
is $batch->[0]{retries},   0, 'job has not been retried';
like $batch->[0]{created}, qr/^[\d.]+$/, 'has created timestamp';
is $batch->[1]{task},      'fail', 'right task';
is_deeply $batch->[1]{args}, [], 'right arguments';
is_deeply $batch->[1]{result}, ['works'], 'right result';
is $batch->[1]{state},      'finished',   'right state';
is $batch->[1]{priority},   0,            'right priority';
is $batch->[1]{retries},    1,            'job has been retried';
like $batch->[1]{created},  qr/^[\d.]+$/, 'has created timestamp';
like $batch->[1]{delayed},  qr/^[\d.]+$/, 'has delayed timestamp';
like $batch->[1]{finished}, qr/^[\d.]+$/, 'has finished timestamp';
like $batch->[1]{retried},  qr/^[\d.]+$/, 'has retried timestamp';
like $batch->[1]{started},  qr/^[\d.]+$/, 'has started timestamp';
is $batch->[2]{task},       'fail',       'right task';
is $batch->[2]{state},      'finished',   'right state';
is $batch->[2]{retries},    0,            'job has not been retried';
is $batch->[3]{task},       'fail',       'right task';
is $batch->[3]{state},      'finished',   'right state';
is $batch->[3]{retries},    0,            'job has not been retried';
ok !$batch->[4], 'no more results';
$batch = $minion->backend->list_jobs(0, 10, {state => 'inactive'});
is $batch->[0]{state},   'inactive', 'right state';
is $batch->[0]{retries}, 0,          'job has not been retried';
ok !$batch->[1], 'no more results';
$batch = $minion->backend->list_jobs(0, 10, {task => 'add'});
is $batch->[0]{task},    'add', 'right task';
is $batch->[0]{retries}, 0,     'job has not been retried';
ok !$batch->[1], 'no more results';
$batch = $minion->backend->list_jobs(0, 1);
is $batch->[0]{state},   'inactive', 'right state';
is $batch->[0]{retries}, 0,          'job has not been retried';
ok !$batch->[1], 'no more results';
$batch = $minion->backend->list_jobs(1, 1);
is $batch->[0]{state},   'finished', 'right state';
is $batch->[0]{retries}, 1,          'job has been retried';
ok !$batch->[1], 'no more results';
ok $minion->job($id)->remove, 'job removed';

# Enqueue, dequeue and perform
is $minion->job(12345), undef, 'job does not exist';
$id = $minion->enqueue(add => [2, 2]);
ok $minion->job($id), 'job does exist';
my $info = $minion->job($id)->info;
is_deeply $info->{args}, [2, 2], 'right arguments';
is $info->{priority}, 0,          'right priority';
is $info->{state},    'inactive', 'right state';
$worker = $minion->worker;
is $worker->dequeue(0), undef, 'not registered';
ok !$minion->job($id)->info->{started}, 'no started timestamp';
$job = $worker->register->dequeue(0);
is $worker->info->{jobs}[0], $job->id, 'right job';
like $job->info->{created}, qr/^[\d.]+$/, 'has created timestamp';
like $job->info->{started}, qr/^[\d.]+$/, 'has started timestamp';
is_deeply $job->args, [2, 2], 'right arguments';
is $job->info->{state}, 'active', 'right state';
is $job->task,    'add', 'right task';
is $job->retries, 0,     'job has not been retried';
$id = $job->info->{worker};
is $minion->backend->worker_info($id)->{pid}, $$, 'right worker';
ok !$job->info->{finished}, 'no finished timestamp';
$job->perform;
is $worker->info->{jobs}[0], undef, 'no jobs';
like $job->info->{finished}, qr/^[\d.]+$/, 'has finished timestamp';
is_deeply $job->info->{result}, {added => 4}, 'right result';
is $job->info->{state}, 'finished', 'right state';
$worker->unregister;
$job = $minion->job($job->id);
is_deeply $job->args, [2, 2], 'right arguments';
is $job->retries, 0, 'job has not been retried';
is $job->info->{state}, 'finished', 'right state';
is $job->task, 'add', 'right task';

# Retry and remove
$id = $minion->enqueue(add => [5, 6]);
$job = $worker->register->dequeue(0);
is $job->info->{retries}, 0, 'job has not been retried';
is $job->id, $id, 'right id';
ok $job->finish, 'job finished';
ok !$worker->dequeue(0), 'no more jobs';
$job = $minion->job($id);
ok !$job->info->{retried}, 'no retried timestamp';
ok $job->retry, 'job retried';
like $job->info->{retried}, qr/^[\d.]+$/, 'has retried timestamp';
is $job->info->{state},     'inactive',   'right state';
is $job->info->{retries},   1,            'job has been retried once';
$job = $worker->dequeue(0);
is $job->retries, 1, 'job has been retried once';
ok !$job->retry, 'job not retried';
is $job->id, $id, 'right id';
ok !$job->remove, 'job has not been removed';
ok $job->fail,  'job failed';
ok $job->retry, 'job retried';
is $job->info->{retries}, 2, 'job has been retried twice';
ok !$job->info->{finished}, 'no finished timestamp';
ok !$job->info->{result},   'no result';
ok !$job->info->{started},  'no started timestamp';
ok !$job->info->{worker},   'no worker';
$job = $worker->dequeue(0);
is $job->info->{state}, 'active', 'right state';
ok $job->finish, 'job finished';
ok $job->remove, 'job has been removed';
is $job->info,   undef, 'no information';
$id = $minion->enqueue(add => [6, 5]);
$job = $worker->dequeue(0);
is $job->id, $id, 'right id';
ok $job->fail,   'job failed';
ok $job->remove, 'job has been removed';
is $job->info,   undef, 'no information';
$id = $minion->enqueue(add => [5, 5]);
$job = $minion->job("$id");
ok $job->remove, 'job has been removed';
$worker->unregister;

# Jobs with priority
$minion->enqueue(add => [1, 2]);
$id = $minion->enqueue(add => [2, 4], {priority => 1});
$job = $worker->register->dequeue(0);
is $job->id, $id, 'right id';
is $job->info->{priority}, 1, 'right priority';
ok $job->finish, 'job finished';
isnt $worker->dequeue(0)->id, $id, 'different id';
$id = $minion->enqueue(add => [2, 5]);
$job = $worker->register->dequeue(0);
is $job->id, $id, 'right id';
is $job->info->{priority}, 0, 'right priority';
ok $job->finish, 'job finished';
ok $job->retry({priority => 100}), 'job retried with higher priority';
$job = $worker->dequeue(0);
is $job->id, $id, 'right id';
is $job->info->{retries},  1,   'job has been retried once';
is $job->info->{priority}, 100, 'high priority';
ok $job->finish, 'job finished';
ok $job->retry({priority => 0}), 'job retried with lower priority';
$job = $worker->dequeue(0);
is $job->id, $id, 'right id';
is $job->info->{retries},  2, 'job has been retried twice';
is $job->info->{priority}, 0, 'low priority';
ok $job->finish, 'job finished';
$worker->unregister;

# Delayed jobs
$id = $minion->enqueue(add => [2, 1] => {delay => 100});
is $worker->register->dequeue(0), undef, 'too early for job';
ok $minion->job($id)->info->{delayed} > time, 'delayed timestamp';
$minion->backend->mysql->db->query(
  "update minion_jobs set `delayed` = DATE_SUB(now(), interval 1 day) where id = ?",
  $id);
$job = $worker->dequeue(0);
is $job->id, $id, 'right id';
like $job->info->{delayed}, qr/^[\d.]+$/, 'has delayed timestamp';
ok $job->finish, 'job finished';
ok $job->retry,  'job retried';
ok $minion->job($id)->info->{delayed} < time, 'no delayed timestamp';
ok $job->remove, 'job removed';
ok !$job->retry, 'job not retried';
$id = $minion->enqueue(add => [6, 9]);
$job = $worker->dequeue(0);
ok $job->info->{delayed} < time, 'no delayed timestamp';
ok $job->fail, 'job failed';
ok $job->retry({delay => 100}), 'job retried with delay';
is $job->info->{retries}, 1, 'job has been retried once';
ok $job->info->{delayed} > time, 'delayed timestamp';
ok $minion->job($id)->remove, 'job has been removed';
$worker->unregister;

# Queues
$id = $minion->enqueue(add => [100, 1]);
is $worker->register->dequeue(0 => {queues => ['test1']}), undef, 'wrong queue';
$job = $worker->dequeue(0);
is $job->id, $id, 'right id';
is $job->info->{queue}, 'default', 'right queue';
ok $job->finish, 'job finished';
$id = $minion->enqueue(add => [100, 3] => {queue => 'test1'});
is $worker->dequeue(0), undef, 'wrong queue';
$job = $worker->dequeue(0 => {queues => ['test1']});
is $job->id, $id, 'right id';
is $job->info->{queue}, 'test1', 'right queue';
ok $job->finish, 'job finished';
ok $job->retry({queue => 'test2'}), 'job retried';
$job = $worker->dequeue(0 => {queues => ['default', 'test2']});
is $job->id, $id, 'right id';
is $job->info->{queue}, 'test2', 'right queue';
ok $job->finish, 'job finished';
$worker->unregister;

# Failed jobs
$id = $minion->enqueue(add => [5, 6]);
$job = $worker->register->dequeue(0);
is $job->id, $id, 'right id';
is $job->info->{result}, undef, 'no result';
ok $job->fail, 'job failed';
ok !$job->finish, 'job not finished';
is $job->info->{state},  'failed',        'right state';
is $job->info->{result}, 'Unknown error', 'right result';
$id = $minion->enqueue(add => [6, 7]);
$job = $worker->dequeue(0);
is $job->id, $id, 'right id';
ok $job->fail('Something bad happened!'), 'job failed';
is $job->info->{state}, 'failed', 'right state';
is $job->info->{result}, 'Something bad happened!', 'right result';
$id  = $minion->enqueue('fail');
$job = $worker->dequeue(0);
is $job->id, $id, 'right id';
$job->perform;
is $job->info->{state}, 'failed', 'right state';
is $job->info->{result}, "Intentional failure!\n", 'right result';
$worker->unregister;

# Nested data structures
$minion->add_task(
  nested => sub {
    my ($job, $hash, $array) = @_;
    $job->finish([{23 => $hash->{first}[0]{second} x $array->[0][0]}]);
  }
);
$minion->enqueue(nested => [{first => [{second => 'test'}]}, [[3]]]);
$job = $worker->register->dequeue(0);
$job->perform;
is $job->info->{state}, 'finished', 'right state';
is_deeply $job->info->{result}, [{23 => 'testtesttest'}], 'right structure';
$worker->unregister;

# Perform job in a running event loop
$id = $minion->enqueue(add => [8, 9]);
Mojo::IOLoop->delay(sub { $minion->perform_jobs })->wait;
is $minion->job($id)->info->{state}, 'finished', 'right state';
is_deeply $minion->job($id)->info->{result}, {added => 17}, 'right result';

# Non-zero exit status
$minion->add_task(exit => sub { POSIX::_exit( 1 ) });
$id  = $minion->enqueue('exit');
$job = $worker->register->dequeue(0);
is $job->id, $id, 'right id';
$job->perform;
is $job->info->{state}, 'failed', 'right state';
is $job->info->{result}, 'Non-zero exit status (1)', 'right result';
$worker->unregister;

# A job needs to be dequeued again after a retry
$minion->add_task(restart => sub { });
$id  = $minion->enqueue('restart');
$job = $worker->register->dequeue(0);
is $job->id, $id, 'right id';
ok $job->finish, 'job finished';
is $job->info->{state}, 'finished', 'right state';
ok $job->retry, 'job retried';
is $job->info->{state}, 'inactive', 'right state';
$job2 = $worker->dequeue(0);
is $job->info->{state}, 'active', 'right state';
ok !$job->finish, 'job not finished';
is $job->info->{state}, 'active', 'right state';
is $job2->id, $id, 'right id';
ok $job2->finish, 'job finished';
ok !$job->retry, 'job not retried';
is $job->info->{state}, 'finished', 'right state';
$worker->unregister;

# Perform jobs concurrently
$id  = $minion->enqueue(add => [10, 11]);
$id2 = $minion->enqueue(add => [12, 13]);
$id3 = $minion->enqueue('test');
my $id4 = $minion->enqueue('exit');
$worker = $minion->worker->register;
$job    = $worker->dequeue(0);
$job2   = $worker->dequeue(0);
my $job3 = $worker->dequeue(0);
my $job4 = $worker->dequeue(0);
my $pid  = $job->start;
my $pid2 = $job2->start;
my $pid3 = $job3->start;
my $pid4 = $job4->start;
my ($first, $second, $third, $fourth);
usleep 50000
  until $first ||= $job->is_finished($pid)
  and $second  ||= $job2->is_finished($pid2)
  and $third   ||= $job3->is_finished($pid3)
  and $fourth  ||= $job4->is_finished($pid4);
is $minion->job($id)->info->{state}, 'finished', 'right state';
is_deeply $minion->job($id)->info->{result}, {added => 21}, 'right result';
is $minion->job($id2)->info->{state}, 'finished', 'right state';
is_deeply $minion->job($id2)->info->{result}, {added => 25}, 'right result';
is $minion->job($id3)->info->{state},  'finished', 'right state';
is $minion->job($id3)->info->{result}, undef,      'no result';
is $minion->job($id4)->info->{state},  'failed',   'right state';
is $minion->job($id4)->info->{result}, 'Non-zero exit status (1)',
  'right result';
$worker->unregister;
$minion->reset;

# worker commands
$worker  = $minion->worker->register->process_commands;
$worker2 = $minion->worker->register;
my @commands;
$_->add_command(test_id => sub { push @commands, shift->id })
  for $worker, $worker2;
$worker->add_command(test_args => sub { shift and push @commands, [@_] })
  ->register;
ok $minion->backend->broadcast('test_id', [], [$worker->id]), 'sent command';
ok $minion->backend->broadcast('test_id', [], [$worker->id, $worker2->id]),
  'sent command';
$worker->process_commands->register;
$worker2->process_commands;
is_deeply \@commands, [$worker->id, $worker->id, $worker2->id],
  'right structure';
@commands = ();
ok $minion->backend->broadcast('test_id'),       'sent command';
ok $minion->backend->broadcast('test_whatever'), 'sent command';
ok $minion->backend->broadcast('test_args', [23], []), 'sent command';
ok $minion->backend->broadcast('test_args', [1, [2], {3 => 'three'}],
  [$worker->id]),
  'sent command';
$_->process_commands for $worker, $worker2;
is_deeply \@commands,
  [$worker->id, [23], [1, [2], {3 => 'three'}], $worker2->id],
  'right structure';
$_->unregister for $worker, $worker2;
ok !$minion->backend->broadcast('test_id', []), 'command not sent';

done_testing();
