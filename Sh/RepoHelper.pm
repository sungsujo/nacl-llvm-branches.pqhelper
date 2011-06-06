#!/usr/bin/perl -w
# -w
# -*- perl -*-


package RepoHelper;
use strict;
use warnings;
use File::Basename;
use File::Temp qw/ tempfile tempdir /; ;
#use IPC::System::Simple;
#use autodie qw(:all);

BEGIN {
  use Exporter   ();
  our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);

  # set the version for version checking
  $VERSION     = 1.00;
  # if using RCS/CVS, this may be preferred
  $VERSION = sprintf "%d.%03d", q$Revision: 1.1 $ =~ /(\d+)/g;

  @ISA         = qw(Exporter);
  @EXPORT      = qw(&GetRepoRoot &QuoteIt &Shell &Piped &GetHgLog 
                    &SaveTestArtifacts &WriteLog 
                    &MergePatchHeader &GetRevName
                    &TagRepo &Merge3
                    &ArgvHasFlag &ArgvHasOpt &ArgvHasUniqueOpt);
  %EXPORT_TAGS = ( );           # eg: TAG => [ qw!name1 name2! ],

  # your exported package globals go here,
  # as well as any optionally exported functions
  @EXPORT_OK   = @EXPORT;
}
our @EXPORT_OK;
END { }       # module clean-up code here (global destructor)

sub TagRepo {
  my ($RepoRoot, $BaseRev, $Tag) = @_;
  chomp($RepoRoot = `pwd`) if ($RepoRoot eq '');
  chdir $RepoRoot;
  print "Tag the repo with $Tag ? ";
  my $ans = <STDIN>;
  if ($ans =~ /y(e(s)?)?/i) {
    Shell("hg qpop -a");
    my (%Log) = &GetHgLog($BaseRev);
    my ($RevName) = &GetRevName(%Log);
    Shell("hg tag -l -r $Log{rev} ${RevName}${Tag}");
  }
}

sub Merge3 {
  my ($RepoDir, $BaseRev, $CurrRev, @Rejected) = @_;
  chomp($RepoDir=`pwd`) if ($RepoDir eq '');
  chdir $RepoDir;

  my (%BaseRevLog) = &GetHgLog($BaseRev);
  my (%CurrRevLog) = &GetHgLog($CurrRev);
  my ($BaseRevName) = &GetRevName(%BaseRevLog);
  my ($CurrRevName) = &GetRevName(%CurrRevLog);

  my (@suffixes) = (qw(.rej -rej .orig -orig));

  my ($TmpDir); chomp ($TmpDir = &tempdir(CLEANUP => 0));
  &WriteLog(\ %BaseRevLog);
  &WriteLog(\ %CurrRevLog);

  my ($Rej);
  foreach $Rej (@Rejected) {
    my ($File, $Dir, $Suffix) = &fileparse($Rej, @suffixes);
    # A: The $File @ $OrigRev
    # B: apply the .rej  to it 
    # C: The current file (which should be at revision $CurrRev)
    Shell("mv $Rej ${TmpDir}", "Copy reject hunk to Output directory");

    if (! -e "${RepoDir}/${Dir}/$File") {
      print "File $Rej does not correspond to an existing file in the repo\n";
    } else {
      Shell("hg cat -r $BaseRevLog{rev} ${Dir}/$File -o ${TmpDir}/${File}.$BaseRevName", 
            "Get version $BaseRevName of  ${Dir}/$File");
      Shell("cp ${TmpDir}/${File}.$BaseRevName ${TmpDir}/${File}",
            "Copy before patching");
      Shell("(cd $TmpDir; patch <${File}${Suffix})", "patch file");
      Shell("kdiff3 ${TmpDir}/${File}.$BaseRevName ${TmpDir}/${File} ${Dir}/${File}");
    }
  }
}

# sub Merge3Loop {
#   my ($RepoDir, 
#       $BaseRevName, $BaseRevLog, 
#       $CurrRev, $CurrRevLog,
# }


sub ArgvHasFlag {
  # returns the list of matching options
  my ($flag) = @_;

  return grep { /^${flag}$/x } (@ARGV);
}

sub ArgvHasOpt {
  #1. for -Option R
  #2. for -Option=R
  #3. for -OptionR
  my ($flag) = @_;
  my ($seenOption) = 0;
  my (@Rtn, $i);
  
  foreach $i (0 .. $#ARGV) {
    $_ =$ARGV[$i];
    if ($seenOption) {
      die "illegal ${\($i+1)} th arg '$_'\n" if (/^$flag/x);
      push @Rtn, $_;
      $seenOption = 0;
    } elsif (/^${flag}$/) {
      $seenOption = 1;
    } elsif (/${flag}=(.*)$/) {
      push (@Rtn, $1);
    } elsif (/${flag}(.*)$/) {
      push (@Rtn, $1);
    }
  }
  return (@Rtn);
}


sub ArgvHasUniqueOpt {
  my ($flag, $var) = @_;
  my (@Rtn) = &ArgvHasOpt($flag);
  die "Can't have more than one '$_[0]'\n" if ($#Rtn > 0);
  return $$var = $Rtn[0] if ($#Rtn == 0);
  return 0;
}

sub GetRepoRoot {
  my ($CMD) = "";
  my ($Dir) = (@_);
  my ($Orig) = $Dir;

  chdir $Dir;
  while ($Dir ne "/") {
    if (-d ".svn") {
      $CMD = "svn"; last;
    } elsif (-d ".hg") {
      $CMD = "hg"; last;
    }
    chdir ("..");
    chomp($Dir = `pwd`);
    # print "Now In $Dir $CMD\n"
  }

  chdir $Orig;
  die "Unable to determine Repo type for '$Orig'\n" if ($CMD eq "");
  return ($CMD, $Dir);
}

sub QuoteIt {
  my ($Cmd) = (@_);
  $Cmd =~ s/\n/\\n/g;
  $Cmd =~ s/\t/\\t/g;
  return $Cmd;
}

sub Shell {
  my ($Cmd, $Comment) = @_;
  my ($CWD) = `pwd`;
  chomp ($CWD);
  print "# $Comment " if ($Comment ne '');
  my $Cmd2 = &QuoteIt($Cmd);
  print "(cd $CWD; $Cmd2)\n";
  system($Cmd) == 0 || 
    die "- $Cmd failed: $?";
}

sub Piped {
  my ($Cmd, $Comment) = @_;
  my ($CWD) = `pwd`;
  chomp ($CWD);
  my ($Fh);
  if ($Cmd !~ /\s\|\s*$/) {
    $Cmd = "$Cmd | ";
  }
  my $Cmd2 = &QuoteIt($Cmd);

  open($Fh, $Cmd) ||
    die "Unable to execute '$Cmd2' as readpipe\n";
  print "# PIPE ";
  print "$Comment " if ($Comment ne '');
  print "(cd $CWD; $Cmd2 )\n";
  my @List = <$Fh>;
  close ($Fh);
  return @List;
}

sub Piped2 {
  my ($Comment, @Cmd) = @_;
  my ($CWD) = `pwd`;
  chomp ($CWD);
  my ($Fh);
  my $Cmd2 = &QuoteIt(join(" ", @Cmd));

  open($Fh, "-|", @Cmd) ||
    die "Unable to execute '$Cmd2' as readpipe\n";
  print "# PIPE ";
  print "$Comment " if ($Comment ne '');
  print "(cd $CWD; $Cmd2 )\n";
  my @List = <$Fh>;
  close ($Fh);
  return @List;
}
sub MergePatchHeader {
  my ($Src, $Dst, $PatchName) = @_;

  print "Merging the patch header from '$Src' to '$Dst'\n";
  open(my $SrcFh, $Src) 
    || die "Unable to open source patch '$Src'\n";
  open(my $DstFh, $Dst) 
    || die "Unable to open destination patch '$Dst'\n";

  my (@Src) = <$SrcFh>;
  my (@Dst) = <$DstFh>;
  close($SrcFh);
  close ($DstFh);
  my (@Header);
  
  while (1) {
    last if ($Src[0] =~ /^diff /);
    push @Header, shift @Src;
  }
  while (1) {
    last if ($Dst[0] =~ /^diff /);
    shift (@Dst)
  }

  push @Header, " From $PatchName\n";
  open ($DstFh, ">$Dst")
    || die "Unable to write to destination patch '$Dst'\n";
  print $DstFh @Header;
  print $DstFh @Dst;
}


sub GetHgLog {
  # get important info about the current rev
  my ($CurrHgRev) = @_;
  if ($CurrHgRev eq '') {
    my (@Rev) = grep { chomp; } Piped("hg id -i");
    $CurrHgRev =  shift @Rev;
    $CurrHgRev =~ s/\+$//g; ## kill any trailing '+'
  }
  my (@Log) = 
    Piped2("Getting Log info for '$CurrHgRev'",
           ("hg", "log", 
            "--debug", "--template=rev:\t\t{rev}:{node}\n".
            "svn:\t\t{svnrev}\n".
            "branches:\t\t{branches}\ntags:\t\t{tags}\n" .
            "children:\t{children}\nparents:\t{parents}\n",
            "-r", ${CurrHgRev}));
  # print @Log;

  my (%Rtn);
  foreach (@Log) {
    $_ =~ /^(\w+):\s+(.*)$/;
    my $Key = $1;
    my $Rest = $2;
    $Rtn{$Key} = $Rest;
  }
  return %Rtn;
}

sub WriteLog {
  my ($Rtn) = (@_);
  my ($Key);
  
  format =
@<<<<<<<<<<<<@<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
$Key, ${$Rtn}{$Key}
.
  my (@keys) = (qw(rev children parents svn tags branches));
  # last line of defense
  foreach (@keys) {
    die "Something went wrong with quering the repository\n" 
      if (! exists ${$Rtn}{$_});;
  }


  foreach $Key (qw(rev children parents svn tags branches)) {
    write;
  }
}

sub GetRevName {
  my (%Log) = @_;
  my ($Rtn) = '';
  my (@tmp);

  if ($Log{svn} ne '') {
    $Rtn = "svn${Log{svn}}";
  } elsif (@tmp = split($Log{tags})) {
    $Rtn = "tag$tmp[0]";
  } else {
    # worst case - use the short id
    @tmp = split(/:/, $Log{rev});
    $Rtn = "rev$tmp[0]";
  }
  return $Rtn;
}

sub SaveTestArtifacts() {
  my($VersionTag, $DstDir, @Dirs) = (@_);
  my($Dir);
  my(@AllArtifacts);
  foreach $Dir (@Dirs) {
    my (@MD5Sums) = Piped("find $Dir -type f | xargs md5sum", "");
    push @AllArtifacts, @MD5Sums;
  }
  @AllArtifacts = sort @AllArtifacts;
  my ($Artifact, $PriorMD5Sum, $PriorArtifact) = ('', '');
  Shell("rm -rf $DstDir/$VersionTag", "");
  Shell("mkdir -p $DstDir/$VersionTag", "");
  $DstDir = "$DstDir/$VersionTag";

  foreach  (@AllArtifacts) {
    chomp;
    /^([a-z0-9]+)\s+(\S.*)$/;
    my ($MD5Sum, $Artifact) = ($1, $2);
    my($A, $P) = &fileparse($Artifact);
    Shell("mkdir -p ${DstDir}/${P}", "");
    if ($MD5Sum eq $PriorMD5Sum) {
      print "  REPEAT $Artifact\n";
      Shell("ln -s -f ${DstDir}/${PriorArtifact} ${DstDir}/${Artifact}", "");
    } else {
      $PriorMD5Sum = $MD5Sum;
      $PriorArtifact = $Artifact;
      print "$MD5Sum // $Artifact\n";
      Shell("cp -a ${Artifact} ${DstDir}/${Artifact}", "");
    }
  }
}

1;
