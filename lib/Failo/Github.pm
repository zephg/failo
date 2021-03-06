package Failo::Github;

use 5.010;
use strict;
use warnings;
use CGI::Simple;
use JSON::XS qw(decode_json);
use List::MoreUtils qw(uniq);
use POE;
use POE::Component::IRC::Common qw(:ALL);
use POE::Component::Server::SimpleHTTP;

sub new {
    my ($package, %args) = @_;
    $args{Method} = 'notice' if !defined $args{Method};
    return bless \%args, $package;
}

sub PCI_register {
    my ($self, $irc) = splice @_, 0, 2;

    POE::Session->create(
        object_states => [
            $self => [qw(_start _http_handler _sig_DIE)],
        ],
    );
    $self->{irc} = $irc;
    return 1;
}

sub PCI_unregister {
    my ($self, $irc) = splice @_, 0, 2;
    $poe_kernel->call($self->{httpd_id}, 'SHUTDOWN');
    $poe_kernel->refcount_decrement($self->{session_id}, __PACKAGE__);
    return 1;
}

sub _start {
    my ($kernel, $self) = @_[KERNEL, OBJECT];

    $kernel->sig(DIE => '_sig_DIE');
    $self->{session_id} = $_[SESSION]->ID();

    $self->{httpd_id} = POE::Component::Server::SimpleHTTP->new(
        PORT     => $self->{bindport} || 0,
        HANDLERS => [
            {
                DIR     => '.*',
                SESSION => $self->{session_id},
                EVENT   => '_http_handler',
            },
        ],
        HEADERS => { Server => 'Failo' },
    )->get_session_id();

    $kernel->refcount_increment($self->{session_id}, __PACKAGE__);
    return;
}

sub _sig_DIE {
    my ($kernel, $self, $ex) = @_[KERNEL, OBJECT, ARG1];
    chomp $ex->{error_str};
    warn "Error: Event $ex->{event} in $ex->{dest_session} raised exception:\n";
    warn "  $ex->{error_str}\n";
    $kernel->sig_handled();
    return;
}

sub _http_handler {
    my ($kernel, $self, $request, $response, $dirmatch)
        = @_[KERNEL, OBJECT, ARG0..ARG2];
    my $irc = $self->{irc};

    # Check for errors
    if (!defined $request) {
        $kernel->call($self->{httpd_id} => 'DONE', $response);
        return;
    }

    my $done = sub {
        $response->code(200);
        $kernel->call($self->{httpd_id} => 'DONE', $response);
    };

    if ($request->method ne 'POST') {
        $done->();
        return;
    }

    # get the channel name
    my $uri = $request->uri;
    my $channel = ($uri->path_segments)[-1];
    if (!$channel) {
        $done->();
        return;
    }
    $channel = "#$channel";
    
    # get the JSON
    my $cgi = CGI::Simple->new($request->content);
    my $info;
    eval { $info = decode_json($cgi->param('payload')) };
    if (!$info) {
        $done->();
        return;
    }

    # header
    my $repo = "$info->{repository}{owner}{name}/$info->{repository}{name}";
    my ($branch) = $info->{ref} =~ m{(?<=^refs/heads/)(.*)};
    return if !defined $branch; # this is probably push --tags
    my $before = substr $info->{before}, 0, 7;
    my $after = substr $info->{after}, 0, 7;
    my $url = @{ $info->{commits} } == 1
        ? "$info->{repository}{url}/commit/$after"
        : "$info->{repository}{url}/compare/$before...$after";
    my $header = BOLD.$repo.NORMAL.' ('.ORANGE.$branch.NORMAL.") $url";
    $irc->yield($self->{Method}, $channel, $header);

    # commit messages
    my @commits;
    for my $commit (@{ $info->{commits} }) {
        my $id = substr $commit->{id}, 0, 7;
        my ($msg) = $commit->{message} =~ /^([^\n]*)/m;
        my $author = $commit->{author}{name};
        my $line = ORANGE."$id ".DARK_GREEN.$author.NORMAL.": $msg";
        push @commits => {
            author => $author,
            line => $line,
        };
    }

    # Always show at least three commits
    my @three = splice @commits, 0, 3;
    $irc->yield($self->{Method}, $channel, $_->{line}) for @three;

    # Maybe we have more
    if (@commits) {
        my $left        = @commits;
        my $left_txt    = $left == 1 ? 'commit' : 'commits';
        my $authors     = uniq(map { $_->{author} } @commits);
        my $authors_txt = $authors == 1 ? 'author' : 'authors';
        my $line        = "... " . BOLD.$left.NORMAL." more $left_txt by ".BOLD.$authors.NORMAL.' '.$authors_txt;
        $irc->yield($self->{Method}, $channel, $line);
    }

    # Dispatch something back to the requester.
    $done->();
    return;
}

1;
