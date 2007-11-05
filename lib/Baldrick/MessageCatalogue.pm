package Baldrick::MessageCatalogue;

# a MessageCatalogue holds messages read from a file and intended to be
# shown to the user.

# This is a shared, re-entrant class; it does not have any state that
# is relevant to the current user (as it may be in use by several users
# or even several apps simultaneously).

use strict;
use FileHandle;

use vars qw(@ISA);
@ISA = qw(Baldrick::Turnip);

sub new # ( %stuff) return Baldrick::Turnip
{
	my ($class, %stuff) = @_;
	
	my $self = {
		catalogues => {},	# tree of { language => { messageid => messagetext } }
		defaultlangs => [ 'en' ]
	};

	bless ($self, $class);
	return $self;
}

sub get
{
	my ($self, $msgid, $language) = @_;

	my @langlist = ( $language, @{ $self->{defaultlangs} } );

	foreach my $lang (@langlist)
	{
		my $tree = $self->{catalogues}->{$lang};
		next if (!$tree);
		
		return $tree->{$msgid} if ($tree->{$msgid});
	}  

	# Not found?  Look for MESSAGE_NOT_FOUND in the appropriate language.
	foreach my $lang (@langlist)
	{
		my $tree = $self->{catalogues}->{$lang};
		my $err =  $tree->{MESSAGE_NOT_FOUND};
		if ($err)
		{
			return sprintf($err, $msgid);
		}
	}

	return sprintf(qq![message "%s" not found]!, $msgid);
}

sub readCatalogueFile
# Read one catalogue file from an already-open filehandle.
# If optional LANG parameter is set, put all entries into that language's table,
# and ignore any '@language' tokens with.  If not set, use '@language xx' directives
# within file to determine which language we're reading now.
{
	my ($self, $fh, $lang) = @_;

	my $oneLanguageFlag = 0;

	if ($lang)
	{
		$oneLanguageFlag = 1;
		$self->{catalogues}->{$lang} ||= {};
	}

	while (my $line = <$fh>)
	{
		chomp($line);
		next if ($line =~ m/^#/);
		# Look for lines beginning with '@' only if language not set when we're called.
		if (! $oneLanguageFlag && (substr($line, 0, 1) eq '@'))
		{
			if ($line =~ m/^\@language (.*)/)
			{	
				$lang = $1;
				$self->{catalogues}->{$lang} ||= {};
			} 
		} elsif ($lang && $line) {
			my ($msgid, $text) = split(/\s+/, $line, 2);
			$self->{catalogues}->{$lang}->{$msgid} = $text;
		} 	
	}
	return 0;
}

sub readCatalogueFiles
{
	my ($self, $fn) = @_;

	if (-f $fn)
	{
		my $fh = new FileHandle();
		if ($fh->open($fn))
		{
			return $self->readCatalogueFile($fh);
		} else {
			$self->abort("cannot read message catalogue file '$fn': $!");
		}
	} else {
		# glob filename.??	 FIX ME
	}

}

1;
