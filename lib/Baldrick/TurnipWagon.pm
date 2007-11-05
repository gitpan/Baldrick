
package Baldrick::TurnipWagon;
use Baldrick::Turnip;
use Baldrick::Util;

# A TurnipWagon is a cache of SpecialTurnips.
use strict;

our @ISA = qw(Baldrick::Turnip);

sub new
{
    my ($class, %args) = @_;
    
    my $s = {
        _wagonLoad => { },
        _turnipClass => $args{turnipClass} || 0,
        _model       => $args{model} || 0,
        _failedLookups => { }, 
    };

    bless ($s, $class);
    $s->addList($args{load}) if ($args{load});
    return $s;
}

sub addItem # ($item, [ key => foo | getkey => \&foo ])
{
    my ($s, $item, %args) = @_;
    
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
    } elsif ($s->{turnipClass}) {
        $key = $item->getUniqueKey();
    } else {
        $key = $item->getUniqueKey();
    }
    return 0 if (!$key);

    # Success; put it inna wagon.
    $s->{_wagonLoad}->{$key} = $item;
    return 1;
}

sub addList
{
    my ($s, $list, %args) = @_;
    return 0 if (! $list);

    my $count = 0;
    foreach my $item (@$list)
    {
        $count+= $s->addItem($item);
    } 
    return $count;
}

sub get # ($key)
{
    my ($s, $key, %args) = @_;
    if (defined ($s->{_wagonLoad}->{$key}))
    {
        return $s->{_wagonLoad}->{$key};
    }

    # not found? put into failedLookups()
    $s->{_failedLookups}->{$key}++;
    return 0;
}

sub getMatching # ($specialTurnip)
{
    my ($s, $other, %args) = @_;
    return $s->get($other->getUniqueKey(), %args);
}

sub getContents
{
    my ($s) = @_;
    return $s->{_wagonLoad};
}

sub getFailedLookupKeys # return LISTREF.
{
    my $foo = $_[0]->{_failedLookups};
    my @bar = keys (%$foo);
    return \@bar;
}

sub loadFromDatabase
{
    my ($s, %args) = @_;
    my $model = $s->getModel() || 
        $s->abort("no model to use loading from database");

    my @inkeys = @{ $args{keylist}};
    my %outkeys;
    foreach my $k (@inkeys) 
    {
        my $x = $k;
        my $p = index($x, '|');
        if ($p)
        {
            $x = substr($x,0,$p);
        }
        $outkeys{$x} = 1;
    } 

    my @outkeys = keys %outkeys;

    my $pklist = $model->splitPrimaryKey();

    my $pk1 = $pklist->[0] || die();

    # FIX ME: this is really not a good way to load them, just 
    # using the first key in the list...
    my $res = $args{database}->query(
        substitute => 1,
        sql => sprintf("select * from %s where %s in (/LIST/)",
            $model->{_tablename}, $pk1),
        sqlargs => \@outkeys, 
        resultclass => $s->{_turnipClass} || ref($model), 
        resultinit => []
    );
    
    return $s->addList($res);
}

sub getModel
{
    my ($s) = @_;

    # Use the model object we were given earlier.
    if ($s->{_model})
    {
        $s->{_model}->checkInitOK();  # maybe init().
        return $s->{_model};
    } 
  
    # ...or create one based on our class. 
    if ($s->{_turnipClass})
    {
        my $x = Baldrick::Util::dynamicNew( $s->{_turnipClass}, softfail_use => 1);
        $x->init();
        $s->{_model} = $x;
        return $x; 
    }  

    # Still none? use the first one in the wagon then...
    my $contents = $s->{_wagonLoad};
    my @keys =keys (%$contents);
    if ($#keys>=0)
    {
        my $x = $contents->{ $keys[0] };
        $s->{_model} = $x;
        return $x;
    } 
    return $s->abort("TurnipWagon cannot find a model SpecialTurnip()");
}

1;
