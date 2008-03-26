
# Session.pm : (c) 2000 Matt Hucke 
#
# v1.0 03/2008

package Baldrick::DatabaseSession;

use strict;
use FileHandle;
use DirHandle;

use Baldrick::Util;
use Baldrick::Session;

our @ISA = qw(Baldrick::Session Baldrick::Turnip);

our $DEFAULT_DELIM = ';;;';

sub init
{
    my ($self, %args) = @_;

    $self->SUPER::init(%args);

    # Avoid passing framework to the Baldrick::DatabaseSession constructor.
    if (my $fr = $args{framework})
    {
        my $dsn = $self->getConfig('database', defaultvalue => 'main') ||
            $fr->abort("database not specified in SessionManager config");
        my $db = $fr->getDatabase($dsn) ||
            $fr->fatalError("cannot open database '$dsn' for sessions");
        $self->{_database} = $db;
    } elsif (my $db = $args{database}) {
        $self->{_database} = $db;
    } else {
        $self->fatalError("no database or framework supplied to init()");
    } 
} 

sub _getDatabase
{
    return $_[0]->{_database};
}

sub _getTableName
{
    my $rv = $_[0]->getConfig('session-table', required => 1);
    $rv =~ s/[^a-z0-9]+//ig;
    return $rv;
}

sub _getFieldMap { return $_[0]->getConfig('FieldMap', defaultvalue => {} ) } 

sub _getFieldName   # warning; no default fieldnames!
{
    my ($self, $label) = @_;
    my $fm = $self->_getFieldMap();

    my $rv = $fm->{$label} || return 0;
    $rv =~ s/[^a-z0-9.]+//ig;
    return $rv;
}

sub _getFieldLength
{
    my ($self, $label) = @_;
    my $fm = $self->_getFieldMap();
    return $fm->{$label} || 4000;
}

sub finish
{
    my ($self) = @_;
    $self->SUPER::finish();

    # must close this AFTER finishing super!
    delete $self->{_database};
}

sub loadAnySession
## Load an existing session file into $args{out}
# DO NOT MODIFY ANY PART OF $self !! 
{
    my ($self, %args) = @_;

    my $sid = requireArg(\%args, 'sid');

    my $db = $self->_getDatabase();
    my $rows = $db->query(
        sql => sprintf("select * from %s where %s=?",
            $self->_getTableName(), $self->_getFieldName('sessionid')
        ),
        sqlargs => [ $sid ] ,
    );

    if ( (!$rows) || ($#$rows < 0) )
    {
        $self->writeLog(sprintf(
            "[Session] cannot load session $sid: %s.\n", $db->getError() || "no rows returned"
            )) unless ($args{quiet});
        return -1;
    }

    my $out = requireArg(\%args, 'out');

    my $keyfield = $self->_getFieldName('key');
    my $valfield = $self->_getFieldName('value');
#    my $combined = $keyfield ? '' : $self->_getFieldName('combined-key-value');
    my $delim = $self->getConfig("combined-key-value-delimiter", defaultvalue => ';;');

    foreach my $row (@$rows)
    {
    # combined format not yet supported because it makes cleanup difficult.
#        if ($combined)  # two column layout: sessionid, combined-key-value
#        {
#            my ($k, $v) = split( m/$delim/, $row->{$combined}, 2);
#            $out->{$k} = $v;
#        } elsif ($keyfield) {   # three columns: sessionid, key, value
            $out->{$row->{$keyfield}} = $row->{$valfield};
#        } 
    } 

    return 0;
}

sub _clearSessionRows
{
    my ($self) = @_;

    my $db = $self->_getDatabase();

    $db->query(nofetch => 1, 
        sql => sprintf("delete from %s where %s=? and %s<>'SESSION_CREATED'", 
            $self->_getTableName(), $self->_getFieldName('sessionid'),
            $self->_getFieldName('key')
        ),
        sqlargs => [ $self->getID() ]
    );
    return 0;
}

sub write # ()
{
    my ($self, %args) = @_;

    my $creating = $args{create} || 0;

    $self->_clearSessionRows();

#    my $verb = $creating ? "creat" : "writ";

    # $self->mutter("${verb}ing session file $fname");

    my @rows;

    my $con = $self->getContents();
    foreach my $k (sort keys %$con)
    {
        # Write SESSION_CREATED only on first write, don't touch it again later.
        next if ($k eq 'SESSION_CREATED' && (!$creating));

        push (@rows, [ $self->getID(), $k, $con->{$k} ]);
    } 

    $self->_getDatabase()->query(
        nofetch => 1, 
        sql => sprintf("insert into %s (%s, %s, %s) values (?,?,?)",
            $self->_getTableName(), 
            $self->_getFieldName('sessionid'),
            $self->_getFieldName('key'), $self->_getFieldName('value')),
        for_arg_lists => \@rows, 
    );
    return 0;
}


sub _idInUse # return true if session with this id exists already
{
	my ($self, $id) = @_;

    my %junk;
    my $rc = $self->loadAnySession(sid => $id, out => \%junk);

    return 1 if (%junk);    # fail if we got something!
    return 0 if ($rc < 0);

	return 0;
}	

sub cleanupExpired
# Clean up other session files that have expired.
{
    my ($self, %args) = @_;

    return 0 unless ($args{maxidle} || $args{lifespan});

    my $delCount = 0;

#        if (Baldrick::Session::_staticCheckSessionExpiration(
#                %args, age =>  $now - $stats[10], idle => $now - $stats[9] )
#            )
    return $delCount;
}

sub getAllSessionMetaInfo   # cannot be static as we need directory name.
{
    my ($self, %args) = @_;
    return {};
}

1;
