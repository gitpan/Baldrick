
# Baldrick::User represents any of these things:
#	- the currently logged-in user
#	- an anonymous user, not logged in
#	- another user in the database (such as one being viewed or edited).

package Baldrick::User;

use strict;
our @ISA = qw(Baldrick::Turnip);

our $ERR_USER_NOT_FOUND = -1;
our $ERR_BAD_PASSWORD   = -2;

sub init
{
	my ($self, %args) = @_;

	$self->{_LoggedIn} = 0;
	$self->{Groups} 	 ||= {};
	$self->{AddressList} ||= [];
    $self->{_PreviousLoginState} = 0;

	return 0;
}

sub onLogin { return 0; }
sub onLogout { return 0; } 

sub setLoggedIn
{
	my ($self, $val) = @_;
	$self->{_LoggedIn} = $val;
}

sub setPreviousLoginState
{
    $_[0]->{_PreviousLoginState} = $_[1];
}

sub getPreviousLoginState
{
    return $_[0]->{_PreviousLoginState};
}

sub loginStateChanged
{
    my ($self) = @_;
    return 1 if ($self->{_LoggedIn} != $self->{_PreviousLoginState});
    return 0;
}

sub _removeFromGroups # ($groupinfo)
{
	my ($self, $groupinfo) = @_;

	my $key = ref($groupinfo) ? $groupinfo->{groupname} : $groupinfo;
    my $allg = $self->{Groups};
    my $rv = $allg->{$key};
    delete $allg->{$key};
	return $rv;
}

sub _addToGroups # ($groupinfo)
# "friend" Baldrick::UserLoader
# used by Loader to import group record when loading.
{
	my ($self, $groupinfo) = @_;

	my $key = $groupinfo->{groupname};
    my $allg = $self->{Groups};
	$allg->{$key} = $groupinfo;
	return $groupinfo;
}

sub _addToAddressList # ($addrinfo)
# "friend" Baldrick::UserLoader
# used by Loader to import address record when loading.
{
	my ($self, $addrinfo) = @_;

	push ( @{ $self->{AddressList} }, $addrinfo);
	return 0;
}

sub getAddress	# ( field => foo, value => bar)
{
	my ($self, %args) = @_;

	my $what = $args{value};
	my $where = $args{field};

	my $alist = $self->{AddressList};
	for (my $i=0; $i<=$#$alist; $i++)
	{
		my $thisaddr = $alist->[$i];
		if ($where && ($what eq $thisaddr->{$where}))
		{
			return $thisaddr;
		} 
	} 
	return 0;
}

sub getAddresses	# () return listref
{
	my ($self) = @_;
	return $self->{AddressList};
}

sub getGroup # ($groupname) return hashref or 0
{
	my ($self, $gname) = @_;
	return $self->{Groups}->{$gname} || 0;
}

sub getGroups	# () return hashref
{
	my ($self) = @_;
	return $self->{Groups};
}

sub getGroupList # () return listref of group names
{
	my ($self) = @_;
	my @rv;
	foreach my $gn (sort keys %{ $self->{Groups} })
	{
		push (@rv, $gn);
	} 
	return \@rv;
}

sub getEmail { return $_[0]->{email}; }
sub getUsername { return $_[0]->{username}; }

sub isLoggedIn # ()
{
	my ($self) = @_;
	return 0 if ( ! defined ($self->{_LoggedIn} ));
	return ($self->{_LoggedIn});
}

sub wasLoggedIn # ()
{
	my ($self) = @_;
	return ($self->{_PreviousLoginState} ? 1:0);
}

sub getLanguage # () return string
# Return user's primary language as a two-letter code (en, de, etc.)
{
	my ($self) = @_;
	return $self->{_language};
}

sub getLanguages # () return list
# Return the user's preferred languages in order of preference 
# as two-letter codes.
# (This is used to locate templates to serve to the user - if the
# list is exhausted without finding a match, template processor 
# should fall back on system default).
{
	my ($self) = @_;
	if ($self->{_language_list})
	{
		return @{$self->{_language_list}};
	} else {
		my @rv;
		push (@rv, $self->getLanguage());
		return @rv;
	}
}

1;
