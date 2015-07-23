#!/usr/bin/perl -w
#use strict;
$| = 1;

use POSIX;
use LWP::UserAgent;
use HTTP::Request;
use HTTP::Headers;

use IO::File;
use Time::Local;
use Device::SerialPort;
use Digest::CRC;

$RDIR = "/var/lib/rrd/parnik";
$RRDTOOL = "/usr/local/rrdtool/bin/rrdtool";

my $secs = time();
my (@args, %opts);
foreach(@ARGV){
   if(/^\-(\S)(.*)/){	$opts{$1} = $2;	} else {	push @args, $_;	}
}
my $verb = exists $opts{v};
my $retries = (exists $opts{r}) ? $opts{r} : 3;
my $showhead = exists $opts{s};	# 
my ($saddr, $device, $passwd, $level) = (@args);
die "Usage: $0 addr serial-dev [passwd [level]]"	unless(defined $saddr && $device);

my $ctx = Digest::CRC->new(width=>16, init=>0xffff, xorout=>0x0000,
                          poly=>0x8005, refin=>1, refout=>1, cont=>0);     
my $addr = sprintf("%x",$saddr);
$passwd = "111111" unless $passwd;
$device = "/dev/tty".$device;
$level = 1 unless $level;

$passwd=sprintf("%x %x %x %x %x %x", split("",$passwd,6));
print "Addr: [$addr] Pw: [$passwd]\n"	if $verb;
my $to_errors = 0;
my $crc_errors = 0;
my $STALL_DEFAULT=4; # how many seconds to wait for new input
my $MAXLENGTH = 255;	# 

my $port=Device::SerialPort->new("$device");
my ($status,$cnt,@data);

if($verb) {
	print "Connection testing ... "	if $verb;
	$status = tst($device,$port,$addr);
	print "$status\n"	if $verb;
	die	"[$addr] Connection failed: [$status]"	unless($status=~/ok/);
}

print "Session opening (level $level) ... "	if $verb;
$status = sopen($device,$port,$addr,$level,$passwd);
print "$status\n"	if $verb;
die	"[$addr] Session failed: [$status]"	unless($status=~/ok/);

my $ts;	# 

$time = time();
$time -= ($time % 300);
#
# Temperatures
#
$ts = "04 01";
$st="U:U:U:U:U:U:U";
for ($try = 0; $try < 3; $try++) {
($status,$cnt,@data) = get($device,$addr,$ts);
	print "Sent: $ts Received: [@data]\n" if $verb;
	if ($status=~/ok/) {
		print "[$status][$cnt][".join(' ',@data)."]\n" if $verb;
		$num = hex(join("",$data[2],$data[1]));
		$temp1 = $num/100. - 30.;
		$num = hex(join("",$data[4],$data[3]));
		$temp2 = $num/100. - 30.;
		$num = hex(join("",$data[6],$data[5]));
		$temp_hi = $num/100. - 30.;
		$temp_lo = $temp_hi - 1;
		$num = hex(join("",$data[8],$data[7]));
		$temp_pump = $num/100. - 30.;
		$st="$temp1:$temp2:U:U:$temp_lo:$temp_hi:$temp_pump";
		last;
	}
}		
$params = "ts=$time&T=$st";
print "T=$st\n" if $verb;
`$RRDTOOL update $RDIR/temp.rrd $time:$st`;
#
# Fans and pump status
#
$ts = "04 03";
$st = "U:U";
for ($try = 0; $try < 3; $try++) {
	($status,$cnt,@data) = get($device,$addr,$ts);
	print "Sent: $ts Received: [@data]\n" if $verb;
	if ($status=~/ok/) {
		print "[$status][$cnt][".join(' ',@data)."]\n" if $verb;
		$st = "$data[1]:$data[2]";
		last;
	}
}
print "M=$st\n" if $verb;
`$RRDTOOL update $RDIR/motor.rrd $time:$st`;
$params .= "&M=$st";
#
# voltage and current
#
$ts = "04 04";
$st = "U:U";
for ($try = 0; $try < 3; $try++) {
	($status,$cnt,@data) = get($device,$addr,$ts);
	print "Sent: $ts Received: [@data]\n" if $verb;
	if ($status=~/ok/) {
		print "[$status][$cnt][".join(' ',@data)."]\n" if $verb;
		$num = hex(join("",$data[2],$data[1]));
		$volt = $num/100. ;
		$st = "$volt:U";
		last;
	}
}
print "P=$st\n" if $verb;
`$RRDTOOL update $RDIR/power.rrd $time:$st`;
$params .= "&P=$st";
#
# volume of water and distance to surface
#
$ts = "04 05";
$st = "U:U";
for ($try = 0; $try < 3; $try++) {
	($status,$cnt,@data) = get($device,$addr,$ts);
	print "Sent: $ts Received: [@data]\n" if $verb;
	if ($status=~/ok/) {
		print "[$status][$cnt][".join(' ',@data)."]\n" if $verb;
		$num = hex(join("",$data[2],$data[1]));
		$vol = $num/100. ;
		$num = hex(join("",$data[4],$data[3]));
		$dist = $num/100. ;
		$st="$vol:$dist";
		last;
	}	
}
print "V=$st\n" if $verb;
`$RRDTOOL update $RDIR/water.rrd $time:$st`;
$params .= "&V=$st";

&http_get($params);

exit;

###################### subs
# проверка связи
sub tst {
	my ($device,$port,$addr) = @_;
	my $cmd = 0;
	my $i = $retries;
	my $res;
	do {
		_send($device,$addr,$cmd);
		$res = isok($device,$port,$addr);
		return $res	if($res =~ /ok/);
		$i--;
		$to_errors++;
	} while($i);
	return $res;
}

# Открытие сессии
sub sopen {
	my ($device,$port,$addr,$level,$pass) = @_;
	my $cmd = 1;
	my $i = $retries;
	my $res;
	do {
		_send($device,$addr,$cmd,$level,$pass);
		$res = isok($device,$port,$addr);
		return $res	if($res =~ /ok/);
		$i--;
		$to_errors++;
	} while($i);
	return $res;
}

# Закрытие сессии
sub sclose {
	my ($device,$port,$addr) = @_;
	my $cmd = 2;
	my $i = $retries;
	my $res;
	do {
		_send($device,$addr,$cmd);
		$res = isok($device,$port,$addr);
		return $res	if($res =~ /ok/);
		$i--;
		$to_errors++;
	} while($i);
	return $res;
}

##########################################################################
sub isok {
	my ($device,$port,$addr) = @_;
	my ($status,$cnt,@data) = _recv($port);
	if($status =~ /ok/) {
		unless(hex($cnt)==4 && hex($data[0])==hex($addr) && hex($data[1])==0) {
			$status = 'fail';
#		} else {
#			# проверить crc
#			$status = iscrc(@data);
		}
	}
	return $status;
}

# проверка crc
sub iscrc {
	my (@data) = @_;
	my $hstr = "";
	for my $i (@data) { $hstr .= sprintf "%02x", hex($i); } 
        my $data = pack ("H*", $hstr);                      
	$ctx->reset;
        $ctx->add($data);                                         
        my $crc16 = $ctx->digest;                       
	$crc_errors++ if $crc16;
	return $crc16 ? 'crc-error' : 'ok';
}

sub _send {                                                      
        my ($device,$addr, @str) = @_;                                            
	my $hstr = "$addr ".join(' ',@str);
	my @a = split / /, $hstr;
	$hstr = "";
	for my $i (@a) { $hstr .= sprintf "%02x", hex($i); } 
        my $data = pack ("H*", $hstr);                      
	$ctx->reset;
        $ctx->add($data);                                         
        my $crc16 = $ctx->digest;                       
        $data .= chr($crc16 & 0xff);                                       
        $data .= chr(($crc16 >> 8) & 0xff);                              
        $port->write($data);                                                 
}                    

sub _recv {
	my ($port) = @_;
	my $timeout=$STALL_DEFAULT * 10;
	$port->read_char_time(0);     # don't wait for each character
	$port->read_const_time(200); # 0,15 second per unfulfilled "read" call
	my $status='ok';
	my $chars=0;
	my @data;
	my $buffer="";
	my ($count,$saw);
	while ($timeout>0) {
		($count,$saw)=$port->read($MAXLENGTH); # will read _up to_ $MAXLENGTH chars
		if ($count > 0) {
			$chars+=$count;
			$buffer.=$saw;
			@data = map {/(..)/gm} unpack("H*",$buffer);
			last;
		}
		else {
			$timeout--;
		}
	}
	if ($timeout==0) {
		$status = 0;	# Waited $STALL_DEFAULT seconds and never saw what I wanted
	}
	$status = iscrc(@data)	if(@data);
	return($status,$count,@data);
}

sub get {
	my ($device,$addr,$ts) = @_;
	my $i = $retries;
	do {
		_send($device,$addr,$ts);
		($status,$cnt,@data) = _recv($port);
		$i--;
		if($status =~ /ok/) {
			$i = 0;
		} else {
			$to_errors++;
		}
	} while($i);
	return($status,$cnt,@data);
}

#############################################################################
# data unpacking
#
sub decimal4 {	# 4 четырехбайтовых числа в строке
	my (@data) = @_;
	# контрольная сумма и байт адреса
	pop @data; pop @data; shift @data;
	my @a;
	foreach my $i (0,4,8,12) {
		my $num = hex(join("",$data[1+$i],$data[0+$i],$data[3+$i],$data[2+$i]));
		push @a, (($num == 4294967295)?'null':$num/1000);
	}
	return @a;
}

sub decimal3 {	# 3 трехбайтных числа в строке
	my (@data) = @_;
	# контрольная сумма и байт адреса
	pop @data; pop @data; shift @data;
	my @a;
	foreach my $i (0,3,6) {
		my $num = hex(join("",sprintf("%02X",(hex($data[0+$i]) & hex("3F"))),$data[2+$i],$data[1+$i]));
		push @a, (($num == 4194303)?'null':$num/100);
	}
	return @a;
}

sub decimal1 {	# 1 трехбайтное число в строке
	my (@data) = @_;
	# контрольная сумма и байт адреса
	pop @data; pop @data; shift @data;
	my @a;
	foreach my $i (0) {
		my $num = hex(join("",sprintf("%02X",(hex($data[0+$i]) & hex("3F"))),$data[2+$i],$data[1+$i]));
		push @a, (($num == 4194303)?'null':$num/100);
	}
	return @a;
}

sub decimal43 {	# 4 трехбайтных числа в строке
	my (@data) = @_;
	# контрольная сумма и байт адреса
	pop @data; pop @data; shift @data;
	my @a;
	foreach my $i (0,3,6,9) {
		my $num = hex(join("",sprintf("%02X",(hex($data[0+$i]) & hex("3F"))),$data[2+$i],$data[1+$i]));
		push @a, (($num == 4194303)?'null':$num/100);
	}
	return @a;
}

##################################################
# Transfer to Web
#

sub http_get {
	my ($params) = @_;
	my $url = "http://www.xland.ru/cgi-bin/parnik_upd";
        my $response = &post_url($url, $params);
print "URL=$url\n";
print "params = $params\n";
print "Response=$response\n";
        return "ok" if $response=~/success/;
        return "fail";
}

#----------
# post_url : Use http to post the url
#----------
sub  post_url ($) {

  my ($url, $ua, $h, $req, $resp, $resp_data, $data);

  ($url, $data) = @_;

# Comment out the fields below for testing, and uncomment the print statement
  $ua = LWP::UserAgent->new;
  $h = HTTP::Headers->new;
  $h->header('Content-Type' => 'text/plain');  # set
  $req = HTTP::Request->new(GET => $url."?".$data, $h);
  $resp = $ua->simple_request($req);
  $resp_data = $resp->content;

# For troubleshooting:
#  print "$url\n";
  return $resp_data;
}
