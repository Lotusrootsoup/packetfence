package pf::services::manager::netdata;

=head1 NAME

pf::services::manager::netdata add documentation

=cut

=head1 DESCRIPTION

pf::services::manager::netdata

=cut

use strict;
use warnings;
use pf::file_paths qw(
    $generated_conf_dir
    $conf_dir
);

use pf::log;
use pf::util;
use pf::cluster;
use pf::constants;
use NetAddr::IP;
use pf::util::dns;

use pf::config qw(
    $management_network
    %Config
);
use pfconfig::cached_array;

use Moo;
extends 'pf::services::manager';

has '+name' => (default => sub { 'netdata' } );
has '+optional' => ( default => sub {'1'} );

tie our @authentication_sources_monitored, 'pfconfig::cached_array', "resource::authentication_sources_monitored";

my $host_id = $pf::config::cluster::host_id;

tie our %NetworkConfig, 'pfconfig::cached_hash', "resource::network_config($host_id)";

=head2 postStartCleanup

Stub method to be implemented in services if needed.

=cut

sub postStartCleanup {
    my ($self,$quick) = @_;
    my $logger = get_logger();
    sleep 40;
    unless ($self->pid) {
        $logger->error("$self->name died or has failed to start");
        return $FALSE;
    }
    return $TRUE;
}

sub generateConfig {
    my ($self,$quick) = @_;
    my $logger = get_logger();
    my %tags;

    $tags{'hosts_cluster_members'} = '';
    if ($cluster_enabled) {
        my $int = $management_network->tag('int');
        $tags{'hosts_cluster_members'} = join(",", grep( {$_ ne $management_network->tag('ip')} values %{pf::cluster::members_ips($int)}));
    }

    $tags{'hosts_dns'} = join(",", @{pf::util::dns::get_resolv_dns_servers()});
    $tags{'hosts_domains'} = ('127.0.0.1');
    $tags{'hosts_sources'} = '';
    foreach my $source  (@authentication_sources_monitored) {
        my $host = $source->{'host'};
        my @hosts;
        if ($host) {
            if (ref($host) eq 'ARRAY') {
                @hosts = @$host;
            } else {
                @hosts = split(",", $host);
            }

        }
        foreach my $source (@hosts) {
            $tags{'hosts_sources'} .= " $source";
        }
        if ($source->{'server1_address'}) {
            $tags{'hosts_sources'} .= " $source->{'server1_address'}";
        }
        if ($source->{'server2_address'}) {
            $tags{'hosts_sources'} .= " $source->{'server2_address'}";
        }
        my $type = $source->{'type'};

        if ($type eq 'Eduroam') {

            $tags{'alerts'} .= <<"EOT";
template: eduroam1__source_available
families: *
      on: statsd_gauge.source.$type.Eduroam1
   every: 10s
    crit: \$gauge != 1
   units: ok/failed
    info: Source eduroam1 unavailable
   delay: down 5m multiplier 1.5 max 1h
      to: sysadmin

template: eduroam2_source_available
families: *
      on: statsd_gauge.source.$type.Eduroam2
   every: 10s
    crit: \$gauge != 1
   units: ok/failed
    info: Source eduroam2 unavailable
   delay: down 5m multiplier 1.5 max 1h
      to: sysadmin

EOT
        } else {
            for my $source_id (@hosts) {
              $tags{'alerts'} .= <<"EOT";
template: $source->{'id'}_source_available
families: *
      on: statsd_gauge.source.$type.$source->{'id'}.$source_id
   every: 10s
    crit: \$gauge != 1
   units: ok/failed
    info: Source $source->{'id'}.$source_id unavailable
   delay: down 5m multiplier 1.5 max 1h
      to: sysadmin

EOT
            }
        }
    }

    foreach my $network ( keys %NetworkConfig ) {
        my $dev = $NetworkConfig{$network}{'interface'}{'int'};
        next if !defined $dev;
        next if isdisabled($NetworkConfig{$network}{'dhcpd'});
        my $net_addr = NetAddr::IP->new($network,$NetworkConfig{$network}{'netmask'});
        my $cidr = $net_addr->cidr();
        $tags{'alerts'} .= <<"EOT";
template: dhcp_missing_leases_$cidr
families: *
      on: statsd_gauge.source.packetfence.dhcp_leases.percentused.$cidr
      os: linux
   hosts: *
   units: %
   every: 1m
    warn: \$gauge > 80
    crit: \$gauge > 90
   delay: down 5m multiplier 1.5 max 1h
    info: DHCP leases usage $cidr
      to: sysadmin

EOT
    }

    $tags{'httpd_portal_modstatus_port'} = "$Config{'ports'}{'httpd_portal_modstatus'}";
    $tags{'management_ip'}
        = defined( $management_network->tag('vip') )
        ? $management_network->tag('vip')
        : $management_network->tag('ip');
    $tags{'db_username'}   = "$Config{'database'}{'user'}";
    $tags{'db_password'}   = "$Config{'database'}{'pass'}";
    $tags{'db_database'}   = "$Config{'database'}{'db'}";
    if ($Config{'database'}{'host'} ne '127.0.0.1' and $Config{'database'}{'host'} ne 'localhost') {
        $tags{'db_dsn'} = "$Config{'database'}{'user'}:$Config{'database'}{'pass'}\@tcp($Config{'database'}{'host'}:$Config{'database'}{'port'})/$Config{'database'}{'db'}";
    } else {
        $tags{'db_dsn'} = "$Config{'database'}{'user'}:$Config{'database'}{'pass'}\@tcp($tags{'management_ip'}:$Config{'database'}{'port'})/$Config{'database'}{'db'}";
    }
    $tags{'active_active_ip'} = pf::cluster::management_cluster_ip() || $management_network->tag('vip') || $management_network->tag('ip');
    $tags{'statsd_listen_port'} = $Config{'advanced'}{'statsd_listen_port'};

    parse_template( \%tags, "$conf_dir/monitoring/netdata.conf", "$generated_conf_dir/monitoring/netdata.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/health.d/bcache.conf", "$generated_conf_dir/monitoring/health.d/bcache.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/health.d/cgroups.conf", "$generated_conf_dir/monitoring/health.d/cgroups.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/health.d/cpu.conf", "$generated_conf_dir/monitoring/health.d/cpu.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/health.d/disks.conf", "$generated_conf_dir/monitoring/health.d/disks.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/health.d/docker.conf", "$generated_conf_dir/monitoring/health.d/docker.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/health.d/entropy.conf", "$generated_conf_dir/monitoring/health.d/entropy.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/health.d/file_descriptors.conf", "$generated_conf_dir/monitoring/health.d/file_descriptors.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/health.d/haproxy.conf", "$generated_conf_dir/monitoring/health.d/haproxy.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/health.d/load.conf", "$generated_conf_dir/monitoring/health.d/load.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/health.d/memory.conf", "$generated_conf_dir/monitoring/health.d/memory.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/health.d/mysql.conf", "$generated_conf_dir/monitoring/health.d/mysql.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/health.d/net.conf", "$generated_conf_dir/monitoring/health.d/net.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/health.d/netfilter.conf", "$generated_conf_dir/monitoring/health.d/netfilter.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/health.d/ping.conf", "$generated_conf_dir/monitoring/health.d/ping.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/health.d/ram.conf", "$generated_conf_dir/monitoring/health.d/ram.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/health.d/redis.conf", "$generated_conf_dir/monitoring/health.d/redis.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/health.d/softnet.conf", "$generated_conf_dir/monitoring/health.d/softnet.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/health.d/statsd.conf", "$generated_conf_dir/monitoring/health.d/statsd.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/health.d/swap.conf", "$generated_conf_dir/monitoring/health.d/swap.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/health.d/systemdunits.conf", "$generated_conf_dir/monitoring/health.d/systemdunits.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/health.d/tcp_conn.conf", "$generated_conf_dir/monitoring/health.d/tcp_conn.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/health.d/tcp_listen.conf", "$generated_conf_dir/monitoring/health.d/tcp_listen.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/health.d/tcp_mem.conf", "$generated_conf_dir/monitoring/health.d/tcp_mem.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/health.d/tcp_orphans.conf", "$generated_conf_dir/monitoring/health.d/tcp_orphans.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/health.d/tcp_resets.conf", "$generated_conf_dir/monitoring/health.d/tcp_resets.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/health.d/timex.conf", "$generated_conf_dir/monitoring/health.d/timex.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/health.d/udp_errors.conf", "$generated_conf_dir/monitoring/health.d/udp_errors.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/health.d/web_log.conf", "$generated_conf_dir/monitoring/health.d/web_log.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/statsd.d/packetfence.conf", "$generated_conf_dir/monitoring/statsd.d/packetfence.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/go.d.conf", "$generated_conf_dir/monitoring/go.d.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/go.d/docker.conf", "$generated_conf_dir/monitoring/go.d/docker.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/go.d/freeradius.conf", "$generated_conf_dir/monitoring/go.d/freeradius.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/go.d/haproxy.conf", "$generated_conf_dir/monitoring/go.d/haproxy.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/go.d/mysql.conf", "$generated_conf_dir/monitoring/go.d/mysql.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/go.d/ping.conf", "$generated_conf_dir/monitoring/go.d/ping.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/go.d/redis.conf", "$generated_conf_dir/monitoring/go.d/redis.conf" );
    parse_template( \%tags, "$conf_dir/monitoring/go.d/web_log.conf", "$generated_conf_dir/monitoring/go.d/web_log.conf" );
    return 1;
}

=head1 AUTHOR

Inverse inc. <info@inverse.ca>


=head1 COPYRIGHT

Copyright (C) 2005-2024 Inverse inc.

=head1 LICENSE

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301,
USA.

=cut

1;
