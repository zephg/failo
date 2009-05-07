#!/usr/bin/env perl

use strict;
use warnings;
use lib 'lib';
use POE;
use POE::Component::IRC::State;
use POE::Component::IRC::Plugin::BotCommand;
use POE::Component::IRC::Plugin::Connector;
use POE::Component::IRC::Plugin::MegaHAL;
use Failo::Identica;
use Failo::Translator;
use Failo::Resolver;
use Failo::TorrentStatus;
use Fcntl ':flock';

open my $self, '<', $0 or die "Couldn't open self: $!";
flock $self, LOCK_EX | LOCK_NB or die "This script is already running";

my $irc_pass = qx/cat bouncer_pass.txt/;
chomp $irc_pass;

my $irc = POE::Component::IRC::State->spawn(
    nick         => 'freenode',
    password     => $irc_pass,
    server       => 'localhost',
    port         => 50444,
    debug        => 1,
    plugin_debug => 1,
);
    
$irc->plugin_add('Connector', POE::Component::IRC::Plugin::Connector->new());
$irc->plugin_add('BotCommand', POE::Component::IRC::Plugin::BotCommand->new(
    Addressed => 0,
    Prefix    => ',',
    Eat       => 1,
));

$irc->plugin_add('Identica', Failo::Identica->new());
$irc->plugin_add('Translator', Failo::Translator->new());
$irc->plugin_add('Resolver', Failo::Resolver->new());
$irc->plugin_add('TorrentStatus', Failo::TorrentStatus->new());

$irc->plugin_add('MegaHAL', POE::Component::IRC::Plugin::MegaHAL->new(
    Own_channel    => '#failo',
    Abuse_interval => 0,
    Talkative      => 1,
    Ignore_regexes => [
        qr{\w+://\w},   # ignore lines containing urls
    ],
));

POE::Session->create(
    inline_states => {
        _start => sub { $poe_kernel->sig(INT => '_int'); $irc->yield('connect') },
        _int   => sub { $irc->yield('shutdown') },
    }
);

$poe_kernel->run();

