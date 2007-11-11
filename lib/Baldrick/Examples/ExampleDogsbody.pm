package Baldrick::Examples::ExampleDogsbody;

=head1 NAME

Baldrick::Examples::ExampleDogsbody - an example Baldrick request handler to be copied

=head1 SYNOPSIS

  DO NOT USE OR INHERIT FROM THIS CLASS.  IT IS AN EXAMPLE ONLY.  
  This file is a template to write your own handler classes.

=head1 USAGE

  # Copy this file to an appropriate location outside of the Baldrick lib directory.
  # Choose a name appropriate for your application.
  $ cp lib/Baldrick/ExampleDogsbody.pm MyNamespace/MyAppHandler.pm

  Edit your handler:
    - get rid of this documentation section
    - change the "package" name to something appropriate (NOT with a Baldrick:: prefix please!)
    - edit init() to have appropriate default_cmd, template dir, etc.
    - put in appropriate handleSomeCommand() functions.

  Edit PathMap and Module sections in baldrick.cfg to point to your new handler:
    in "PathMap": /my/url/path = MyModuleName
    in "Module MyModuleName": handler-class = MyNamespace::MyAppHandler

=cut

use strict;
use Baldrick::Util;     # some good functions exported here.
use Baldrick::Dogsbody; # parent class.

our @ISA = ( 'Baldrick::Dogsbody', @Baldrick::Dogsbody::ISA);

# Sequence of events:
#   init()          [ call super's init() with essential startup options ]
#   prepareRun()    [ defined in superclass, usually not overridden - loads the user. ]
#   beginRun()      [ override this for your local startup stuff (optional) ]
#   handleXxxxxx()  [ handlers for user-specified commands in CGI parameter "cmd=COMMAND[:ARG]" .  
#                     First char and any char after "-" are upcasse'd. Anything after ':' goes
#                      into "cmdargs", isn't part of command ]
#   endRun()        [ override this for your local cleanup stuff (optional) ]
#   afterRun()      [ superclass's cleanup, usually not overridden - writes session changes ]
sub init
{
    my ($self, %args) = @_;

    # Send debug output to browser - comment out when done debugging.
    $self->{_debug} = 'U';  

    $self->SUPER::init(%args,
        # what to do when user doesn't supply "cmd=something".
        default_cmd => 'test',

        # a subdir relative to config file's "template-base"
        templatedir => 'example',   
    
        # error page template - your template engine's preferred suffix
        # will be appended. 
        errortemplate => 'error'
    );

    # At this point the objects based on the current request (user, session, validator)
    # are NOT ready for use - they are set up after init() is done.  If you need to do startup
    # stuff that takes the current request into account, do it in beginRun(), which happens
    # next.

    return $self;
}

sub beginRun
# When beginRun() is called, objects based on the current request (user, session, validator)
# are fully initialised and ready for use.  If the user is attempting login, that will have
# succeeded (or failed) before this point is reached.
{
    my ($self, %args) = @_;
    # General setup stuff here - create objects, open logs, etc.  

    my $req = $self->getRequest();
    my $ssn = $self->getSession();
    my $user = $self->getCurrentUser();

    if ( ! $user->isLoggedIn())
    {
        # $self->abort("Access Denied");
    } 
    # ...

    # beginRun() is for SETUP tasks only - don't do any actions or output generation
    # here.  Those happen next, in handle_____() functions.
    return 0;
}

## COMMAND HANDLERS.
# The CGI variable "cmd" takes the following form (brackets for optional parts):
#
#   cmd = command[:arg] [ "|" command2[:arg2] ]...
#   
# The full command is split apart at the pipe ("|") characters.  Each piece is 
# further split at the colon, if present, with the left half being a command, the
# right half its optional argument.

# examples: 
#   cmd=read-messages   # A very simple command, no argument.
#   cmd=add:1*WIDGET    # a command with an argument, to "add" a widget to a shopping cart.
#                       # (parsed as cmd="add", cmdargs="1*WIDGET")
#   cmd=add:1*WIDGET|checkout   # a compound command that will be sent to two handle____()
#                       # functions in sequence.
# Once the command list is parsed, the request is sent to a handle____() function.
#   The command name is transformed: everything but [A-Za-z0-9] is thrown out, with 
#   the first character and every character after "-" or "_" promoted to uppercase.
#       cmd=test            becomes handleTest()
#       cmd=add-to-cart     becomes handleAddToCart()
#       cmd=look_At_ME      becomes handleLookAtME()
#       cmd=@*^fred         becomes handleFred() [ rubbish chars thrown away, leaving 'fred' ]
#       cmd=@($$^%          gives a fatal error, nothing good left after rubbish thrown out.
sub handleTest
{
    my ($self, %args) = @_;

    # %args contains:
    #   cmd = name of current command in command list (see above).  Note that it was already
    #       used to look up this function name ("test" becomes "handleTest()"), 
    #       so you won't often need to look at it here.
    #   cmdargs = optional arg for current command (the part after the ":")
    #   cmdlist = list of commands (each listitem is { cmd=> .., arg => .. } )
    #   cmdcount = number of commands in list (usually 1)
    #   cmdindex = index of current command in list (usually 0)
    #   last    = true if this is last command in list (generally yes)

    $self->sendOutput(text => "<h4>I am an example handler, class " . ref($self) . "</h4>\n");
    $self->sendOutput(dump => \%args, 
        headline => "<h4>The arguments to my handleTest() function are: </h4>\n");

    my $req = $self->getRequest();
    $self->sendOutput(dump => $req->getContents(),
        headline => "<h4>The CGI parameters from the user's query string are: </h4>\n");

    $self->sendOutput(text => "<h4>Here is an example template in my preferred template system, " .
        ref ($self->getOut()) . "</h4>");

    $self->sendOutput(template => "example-template");

    my $ssn = $self->getSession();
    $self->sendOutput(dump => $ssn->getContents(), 
        headline => "<h4>The user's session is a " . ref($ssn) . " and looks like: </h4>\n");

    # my $db = $self->getDatabase();    

    return 0;   # return value is ignored.  I like zero.
}

sub handleSomethingElse
{
    my ($self, %args) = @_;

    $self->sendOutput(text => "This is the handle function for a different command.  
        Handlers typically have many handleXXXXXX() functions.");
}

sub handleUnknownCommand
# This is called when the "cmd" CGI param is gibberish.  The superclass has one that
# returns an error message; override it here if you want something fancier.
{
    my ($self, %args) = @_;

    return $self->sendOutput(error => qq|I don't know what you mean by "$args{cmd}".|);
}

1;
