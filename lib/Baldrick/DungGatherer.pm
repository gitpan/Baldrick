
# Baldrick::DungGatherer - initial version 2007/09/25

# A factory for creating Dogsbody (and descendant) objects.  

package Baldrick::DungGatherer;

use strict;
use Baldrick::Util;
use Baldrick::Turnip;

our @ISA = qw(Baldrick::Turnip);

sub init
{
    my ($self, %args) = @_;

    $self->{_framework} ||= $args{framework};
    if (my $mi = $args{moduleinfo})
    {
#        $self->setModuleInfo($mi);
        # Don't save it; save it when we do startRequest().
    }

    # The config tree from the parent will be modified by adding
    # ModuleConfig sections to it.
    $self->setConfigRoot($args{framework}->getConfigRoot());
    
    $self->{created} = time();
    $self->{active} = 0;
    $self->{_requestObjects} = 0;

    return $self;
}

sub getFramework
{
    my ($self) = @_;
    return $self->{_framework};
}

sub setRequestObjects { $_[0]->{_requestObjects} = $_[1]; }
sub getRequestObjects { return $_[0]->{_requestObjects}; }
sub setModuleInfo { $_[0]->{_moduleInfo} = $_[1]; }
sub getModuleInfo { return $_[0]->{_moduleInfo}; }

sub startRequest
{
    my ($self, %args) = @_; 

    $self->{active} = 2;

    my $modinf = requireArg(\%args, 'moduleinfo');
    my $framework = requireArg(\%args, 'framework');
    $self->setModuleInfo($modinf);

    my $def = $modinf->{definition};
    
    # set up request Objects,
    my $ro = {  
        request => requireArg(\%args, 'request'), 
        config => {}
    };

    if (my $cfgfile = $def->{'module-config'})
    {
        $ro->{config} = $self->_loadModuleConfig($modinf->{module}, $cfgfile); 
    } 

    $ro->{session} = (defined $args{session}) ?  $args{session} :
        $self->_loadSession( %$ro, label => $def->{'session-manager'} );

    $ro->{userloader} = (defined $args{userloader}) ? $args{userloader} :
        $framework->getUserLoader( $def->{"user-class"} || 'default' );

    $self->{_requestObjects} = $ro;

    return $ro;
}

sub createHandler
{
    my ($self, %args) = @_;

    my $modinf = $self->getModuleInfo();
    my $moddef = $modinf->{definition};

    my $handlerClass = $moddef->{'handler-class'} || 'Baldrick::Dogsbody';
    my $dogsbody = dynamicNew($handlerClass);

    $dogsbody->init(
        app => requireArg(\%args, 'framework'), 
        %{ $self->getModuleInfo() },
        %{ $self->getRequestObjects() },
    );
    return $dogsbody;
}

sub _loadModuleConfig
{
    my ($self, $module, $filename) = @_;

    $self->abort("module name missing") if (!$module);

    # See if it is already loaded.
    my $modconfig = $self->getConfigSection("ModuleConfig/$module");
    return $modconfig if ($modconfig);

    return {} if (!$filename);
    
    my $cfgobj = loadConfigFile($filename, want_object => 1);
    if ($cfgobj)
    {
        $modconfig = $cfgobj->{config};
    } else {
        $self->abort("Module config file '$filename' for module '$module' not found");
    }

    my $topnode = $self->getConfigRoot();
    $topnode->{ModuleConfig} = {} unless ($topnode->{ModuleConfig});
    $topnode->{ModuleConfig}->{$module} = $modconfig;

    return $modconfig;
}

sub _loadSession # ( request => .., cfglabel => ..)   
# Load a user session for a request.
{   
    my ($self, %args) = @_;

    my $req = requireArg(\%args, 'request');
    my $label = $args{label} || 'default';

    my $session = 0;
    if ($label eq 'null' || $label eq 'none')
    {
        # Null session manager with default config
        $session = Baldrick::Session::factoryCreate(
            config => { type => 'null' },
            servername => $req->getServerName(),
        );
    } else {
        # Regular session manager (might also be null sessions, but with config)
        my $cfg = $self->getConfig($label, section => "SessionManager",
            defaultvalue => { }, warning => 1
        );
        $session = Baldrick::Session::factoryCreate(
            label => $label, config => $cfg, creator => $self,
            request => $req, servername => $req->getServerName(),
            framework => $self->getFramework()
        );
    }

    # Load from file/database/whatever.
    $session->open(request => $req );

    return $session;
}

sub finishRequest
{
    my ($self, $req) = @_;
    
    return 0;
}

1;
