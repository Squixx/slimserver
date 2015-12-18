package Slim::Plugin::RemoteLibrary::ProtocolHandler;

use strict;
use base qw(Slim::Player::Protocols::HTTP);

use JSON::XS::VersionOneAndTwo;
use Scalar::Util qw(blessed);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;

my $log = logger('plugin.remotelibrary');

my $cache = Slim::Utils::Cache->new;

sub canSeek { 1 }

sub isRemote { 1 }

# Source for AudioScrobbler
sub audioScrobblerSource {
	# P = Chosen by the user
	return 'P';
}

# Avoid scanning
sub scanUrl {
	my ($class, $url, $args) = @_;
	$args->{cb}->($args->{song}->currentTrack());
}

sub getNextTrack {
	my ( $class, $song, $successCb, $errorCb ) = @_;
	
	my $url = $song->track()->url;
	my ($baseUrl, $uuid, $id, $file) = _parseUrl($url);

	$url = $baseUrl . join('/', 'music', $id, $file);
	
	main::DEBUGLOG && $log->is_debug && $log->debug("Setting streaming URL: $url");
	
	$song->streamUrl($url);
	
	$successCb->();
}

sub getMetadataFor {
	my ( $class, $client, $url, $forceCurrent ) = @_;
	
	my $meta = $cache->get('remotelibrary_' . $url);
	my $song = $client->playingSong();

	my ($baseUrl, $uuid, $id, $file) = _parseUrl($url);

	if ($song && $song->streamUrl && $song->streamUrl eq $url) {
		$song->streamUrl($baseUrl . join('/', 'music', $id, $file));
	}
	
	if ( !$meta && !$client->pluginData('fetchingMetadata') ) {
		$client->pluginData( fetchingMetadata => 1 );

		# Go fetch metadata for all tracks on the playlist without metadata
		my $need = {
			$id => $url
		};
		
		for my $track ( @{ Slim::Player::Playlist::playList($client) } ) {
			my $trackURL = blessed($track) ? $track->url : $track;
			if ( $trackURL && $trackURL =~ /$uuid/ && (my (undef, undef, $id) = _parseUrl($trackURL)) ) {
				if ( $id && !$cache->get("remotelibrary_$trackURL") ) {
					$need->{$id} = $trackURL;
					# only fetch 50 tracks in one query
					last if scalar keys %$need > 50;
				}
			}
		}
		
		Slim::Plugin::RemoteLibrary::Plugin::remoteRequest($uuid, 
			[ '', ['titles', 0, 999, sprintf('search:sql=tracks.id IN (%s)', join(',', keys %$need)), 'tags:acdgilortyY']],
			\&_gotMetadata,
			sub {},
			{
				client  => $client,
				idUrlMap => $need,
			},
		);
	}
	
	if ($meta && keys $meta) {
		$song->duration($meta->{duration}) if $song && $meta->{duration};

		# bitrate is a formatted string (eg. "320kbps") - need to transform into number
		if (my $bitrate = $meta->{bitrate}) {
			$bitrate = $bitrate * 1.0;
			$bitrate *= 1000 if $bitrate !~ /^\d{5,}$/;
			$song->bitrate($bitrate) if $song && $bitrate;
		}
	}
	
	return $meta || {};
}

sub _gotMetadata {
	my ($result, $args) = @_;
	
	my $client = $args->{client};
	my $idUrlMap = $args->{idUrlMap};
	
	if ( !($result && $result->{titles_loop}) ) {
		$log->error( 'Unexpected response data: ' . Data::Dump::dump($result) );
		
		# fill in some fake metadata to prevent looping lookups
		$result->{titles_loop} = [ map {
			id => $_
		}, keys %$idUrlMap ];
	}

	foreach my $meta ( @{$result->{titles_loop}} ) {
		next unless $meta->{id} && (my $url = $idUrlMap->{$meta->{id}});
	
		if ($meta->{coverid}) {
			my (undef, $remote_library) = _parseUrl($url);
			$meta->{cover} = Slim::Plugin::RemoteLibrary::Plugin::_proxiedImage({
				'image' => delete $meta->{coverid}
			}, $remote_library);
		}

		$cache->set('remotelibrary_' . $url, $meta);
	}
	

	if ($client) {
		$client->pluginData( fetchingMetadata => 0 );
	}

	# Update the playlist time so the web will refresh, etc
	$client->currentPlaylistUpdateTime( Time::HiRes::time() );
	
	Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
}

sub _parseUrl {
	my $url = shift;
	
	my ($uuid, $id, $file) = $url =~ m|lms://(.*?)/music/(\d+?)/(.*)|;
	my $baseUrl = Slim::Plugin::RemoteLibrary::Plugin->baseUrl($uuid);
	
	return ($baseUrl || '', $uuid, $id, $file);
}

1;