
package Baldrick::TurnipWagon;
use Baldrick::Turnip;
use Baldrick::Util;
use Carp;

# A TurnipWagon is a cache of SpecialTurnips.
use strict;

our @ISA = qw(Baldrick::Turnip);

sub init
{
    my ($self, %args) = @_;
   
    $self->SUPER::init(%args,
        copyDefaults => {
            turnipClass => 0,
            model => 0,
        }
    );

    $self->{_wagonLoad} ||= {};
    $self->{_failedLookups} ||= { };

    $self->addList($args{load}) if ($args{load});
    return $self;
}

sub addItem # ($item, [ key => foo | getkey => \&foo ])
{
    my ($self, $item, %args) = @_;
    
    return 0 if (!$item);    

    # Get the unique key for this object.
    # use 'key' parameter if present, 
    # next try calling function from getkey param
    # next call item's getUniqueKey
    my $key = 0;
    if (defined($args{key}) && $args{key}) 
    {
        $key = $args{key};
    } elsif (defined ($args{getkey})) {
        my $keyfunc = $args{getkey};
        $key = &{$keyfunc}($item);
    # } elsif ($self->{turnipClass}) {
    #   $key = $item->getUniqueKey();
    } else {
        $key = $item->getUniqueKey();
    }
    return 0 if (!$key);

    # Success; put it inna wagon.
    $self->{_wagonLoad}->{$key} = $item;
    return 1;
}

sub addList
{
    my ($self, $list, %args) = @_;
    return 0 if (! $list);

    my $count = 0;
    foreach my $item (@$list)
    {
        $count+= $self->addItem($item);
    } 
    return $count;
}

sub get # ($key)
{
    my ($self, $key, %args) = @_;
    if (defined ($self->{_wagonLoad}->{$key}))
    {
        return $self->{_wagonLoad}->{$key};
    }

    # not found? put into failedLookups()
    $self->{_failedLookups}->{$key}++;
    return 0;
}

sub getMatching # ($specialTurnip)
{
    my ($self, $other, %args) = @_;
    return $self->get($other->getUniqueKey(), %args);
}

sub getContents
{
    my ($self) = @_;
    return $self->{_wagonLoad};
}

sub getFailedLookupKeys # return LISTREF.
{
    my ($self) = @_;
    my $foo = $self->{_failedLookups};
    my @bar = keys (%$foo);
    return \@bar;
}

sub loadFromDatabase    # ( keylist => LIST )
{
    my ($self, %args) = @_;
    my $model = $self->getModel() || 
        $self->fatalError("no model to use loading from database");

    my @inkeys = @{ $args{keylist}};
    my %outkeys;
    foreach my $k (@inkeys) 
    {
        my $x = $k;
        if (my $p = index($x, '|'))
        {
            $x = substr($x,0,$p);
        }
        $outkeys{$x} = 1;
    } 

    my @outkeys = keys %outkeys;

    my $pklist = $model->getPrimaryKeys(combined => 1);

    my $pk1 = $pklist->[0] || die();

    # FIX ME: this is really not a good way to load them, just 
    # using the first key in the list...
    my $tnames = $model->getTableNames();

    my $res = $args{database}->query(
        substitute => 1,
        sql => sprintf("select * from %s where %s in (/LIST/)",
            $tnames->[0], $pk1),
        sqlargs => \@outkeys, 
        resultclass => $self->{_turnipClass} || ref($model), 
        resultinit => []
    );
    
    return $self->addList($res);
}

sub setModel
# Stash a model turnip which will be used to get parameters for constructing others.
{
    my ($self,$m) = @_;
    $self->{_model} = $m;
    return $m;
}

sub getModel
# Retrieve the model turnip (creating it if necessary).
{
    my ($self) = @_;

    # Use the model object we were given earlier.
    if (my $m = $self->{_model})
    {
        $m->checkInitOK();  # maybe init().
        return $m;
    } 
  
    # ...or create one based on our class. 
    if (my $tc = $self->{_turnipClass})
    {
        my $m = Baldrick::Util::dynamicNew( $tc, softfail_use => 1);
        $m->init();
        return $self->setModel($m); 
    }  

    # Still none? use the first one in the wagon then...
    my $contents = $self->{_wagonLoad};
    my @keys = keys (%$contents);
    if ($#keys>=0)
    {
        my $m = $contents->{ $keys[0] };
        return $self->setModel($m); 
    } 
    return $self->abort("TurnipWagon cannot find a model SpecialTurnip()");
}

1;
