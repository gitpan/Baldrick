
package Baldrick::QueryBuilder;
use strict;
use Baldrick::Util;

our @ISA = qw(Baldrick::Turnip);

sub init
{
    my ($self, %args) = @_;

    $self->SUPER::init(%args,
        copyRequired => [ qw(tables basetable) ],
        copyDefaults => {
            wherelist => [],
            whereargs => [], 
            sortorder => [], 
            conjunction => 'AND',
            activeTables => [], 
        }
    );

    $self->activateTable($self->{_basetable});

    return $self;
}

sub getTableInfo
{
    my ($self, $tn, %args) = @_;

    my $ti = $self->{_tables};
    if (my $rv = $ti->{$tn})
    {
        return $rv;
    } elsif (! $args{softfail} ) {
        $self->fatalError(ref($self) . "::getTableInfo: I don't know $tn");
    } 
}

sub getActiveTableList
{
    return $_[0]->{_activeTables};
}

sub tableIsActive
{
    my ($self, $tn) = @_;

    my $tlist = $self->getActiveTableList();
    foreach my $x (@$tlist)
    {
        return 1 if ($x eq $tn);
    } 
    return 0;
}

sub addWhere
{
    my ($self, %args) = @_;

    my $what = requireAny(\%args, [ qw(paramlist value fieldname) ]);
    my $pValue = $args{$what};

    my $paramList = 0;

    if ($what eq 'paramlist')
    {
        $paramList = ref($pValue) ? $pValue : [ $pValue ];
    } elsif ($what eq 'value') {
        $paramList = [ $pValue ];
    } elsif ($what eq 'fieldname' ) {
        my $source = requireArg(\%args, 'source');
        if (defined($source->{$pValue}))
        {
            $paramList = [ $source->{$pValue} ];
        } else {
            $paramList = [ requireArg(\%args, 'defaultvalue') ]; 
        } 
    }  

    my $expr = requireArg(\%args, 'expr');
    if ($args{substitute})
    {
        my $foo = ('?,' x $#$paramList) . '?';
        $expr =~ s#/LIST/#$foo#g; 
    }  
    
    push (@{ $self->{_wherelist} }, $expr); 
    push (@{ $self->{_whereargs} }, @$paramList);
    return 1;
}
   
sub activateTable
{
    my ($self, $table) = @_;

    return 0 if ($self->tableIsActive($table));

    my $at = $self->getActiveTableList();
    push (@$at, $table);
    return 1;
}

sub getSelectColumns    # ( want_string => 0 ) return LIST or string of active table columns
{
    my ($self, %args) = @_;

    my @out;

    foreach my $table (@{ $self->getActiveTableList() })
    {
        my $tinfo = $self->{_tables}->{$table};
        my $fl = $tinfo->{columns};
        if (ref($fl))
        {
            push (@out, @$fl);
        } elsif ($fl) {
            push (@out, split(/,\s*/, $fl));
        } else {
            push (@out, "$table.*");
        }
    } 

    if ($args{want_string})
    {
        return join(",", @out);
    } else {
        return \@out;
    }
}

sub buildWhere
{
    my ($self) = @_;

    my $conj = $self->{_conjunction} || 'AND';
    my $rv = join(" $conj ", @{ $self->{_wherelist} });
    return $rv;
}

sub buildOrderBy
{
    my ($self) = @_;
    my $so = $self->{_sortorder} || return '';
    if (ref($so))
    {
        return join(", ", @$so);
    } else {
        return $so;
    } 
}

sub setSortOrder
{
    my ($self, $so) = @_;
    $self->{_sortorder} = $so;
}

sub hasGoodWhere
{
    my ($self) = @_;

    my $wl = $self->{_wherelist};
    return 0 if ($#$wl < 0);
    return 1;
}

sub buildQuery
{
    my ($self, %args) = @_;

    if (! $self->hasGoodWhere())
    {
        return ( { errorcode => 'EMPTY', errormessage => 'No search terms were given.' } );
    } 

    my $sql = sprintf("SELECT %s from %s ", 
        $self->getSelectColumns(want_string => 1), $self->{_basetable}
    );

    my %seen = ( $self->{_basetable} => 1 );
    foreach my $table ( @{ $self->getActiveTableList() } )
    {
        next if ($seen{$table});
        $seen{$table} = 1;

        my $tinfo = $self->getTableInfo($table);
        if (my $fred = $tinfo->{sqljoin}) 
        {
            $sql .= ' ' . $fred;
        } else {
            $self->fatalError("no 'sqljoin' for table $table");
        } 
    } 

    $sql .= " WHERE " . $self->buildWhere();
    if (my $oby = $self->buildOrderBy())
    {
        $sql .= " ORDER BY $oby"; 
    } 
    $self->{_sqlText} = $sql;

    my $rv = {
        sql => $sql,
        sqlargs => $self->{_whereargs},
    };
    return $rv;
}
 
1;
