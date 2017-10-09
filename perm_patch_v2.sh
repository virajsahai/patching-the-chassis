#!/bin/bash

usage()
{   
	echo 'This command can be used to permanent patch testmodules and chassis.'
	echo
	echo "Usage : $0 -c <patch chassis?> -mp <multiple patch?> [-src <source of file/file-list>] [-dest <destination folder/folder-list>] [-s <zero-indexed slot>] "
	echo
	echo '-c    : Set 1 to patch chassis. 0 to patch testmodule'
	echo '-mp   : Set 1 to patch multiple files. 0 to patch just a single file. '
	echo '        Note: When -mp is 1 during chassis patch, script expects a package.'
	echo '-src  : (Optional) Source of the package/file/file-list to patch. Note: If -mp is set during testmodule patching, script expects a file with list of sources.'
	echo '        Note: During chassis patching, script will expect a .tgz package.'
	echo '-dest : (Optional) Destination of folder/folder-list to patch. Default is bin folder. Note: End destination with /, like, /mnt/spirent/ccpu/bin/'
	echo '        Note: If patching multiple files, make sure the source and destination match correspondingly'
	echo '-s    : (Optional) Zero Indexed Slot to patch. Only applicable if -c is set to 0'	
	echo
}

kill_nbd()
{
	nbd_pids=`ps aux | grep nbd | grep -v grep | awk '{ print $2 }'`
	for pid in $nbd_pids
	do
		if [ ! -z $pid ];
		then
			kill -9 $pid
		fi
	done
}

cleanup()
{
	rm -r $HOME/tmp.*
}

error_occured()
{
	rm -rf /mnt/spirent/testmodule/slot$1/*
	cp -r $HOME/tmp.slot/* /mnt/spirent/testmodule/slot$1/
	cleanup
	echo
	echo "Error occurred. Exiting now. Please try again!"
	echo
	exit
}

yocto_lxc()
{
	if [ ! -e "$1" ];
	then
		echo
		echo "Error: Invalid source file! Exiting!"
		cd "$5"
		error_occured "$4"
	fi

	cd /mnt/spirent/testmodule/slot$4
	mkdir patch
	cd patch
	mv ../$3 .
	tar xzf $3
	rm $3

	if [ ! -e base.qcow2 ];
	then
		cd "$5"
		echo
		echo "Error: base.qcow2 of the VM to be patched is not present. Exiting!!"
		error_occured "$4"
	fi 
	
	kill_nbd
	sync;sync
	sleep 2
	mkdir -p vm_image
	modprobe nbd max_part=63
	qemu-nbd -c /dev/nbd0 base.qcow2
	sleep 2
	mount /dev/nbd0p1 vm_image/
	cd vm_image/
	cd lxc
	while true
	do
		read -r file_loc <&3 || break
		read -r dest <&4 || break
		# should always close open FDs before calling other functions because of inheritance
		cd ccpu1$dest
		cp $file_loc .
		cd ../../../../../
		cp $file_loc ccpu2$dest
		cp $file_loc ccpu3$dest
		cp $file_loc ccpu4$dest
		cd ..
		cd .$dest
		cp $file_loc .
		cd ../../../	
		cd ../lxc
		# note that fd3 and fd4 are still open in the loop
	done 3<$1 4<$2
	cd ../../
	umount vm_image
	rmdir vm_image/
	tar czf $3 *
	mv $3 ..
	rm *
	cd ..
	rm -r patch
}

yocto_non_lxc()
{
	if [ ! -e "$1" ];
	then
		echo
		echo "Error: Invalid source file! Exiting!"
		cd "$5"
		error_occured "$4"
	fi

	cd /mnt/spirent/testmodule/slot$4
	mkdir patch
	cd patch
	mv ../$3 .
	tar xzf $3
	rm $3

	if [ ! -e base.qcow2 ];
	then
		cd "$5"
		echo
		echo "Error: base.qcow2 of the VM to be patched is not present. Exiting!!"
		error_occured "$4"
	fi 

	kill_nbd
	sync;sync
	sleep 2
	mkdir -p vm_image
	modprobe nbd max_part=63
	qemu-nbd -d /dev/nbd0
	sleep 2
	qemu-nbd -c /dev/nbd0 base.qcow2
	sleep 2
	mount /dev/nbd0p1 vm_image/
	while true
	do
		read -r file_loc <&3 || break
		read -r dest <&4 || break
		# should always close open FDs before calling other functions because of inheritance
		cp $file_loc vm_image$dest
		# note that fd3 and fd4 are still open in the loop
	done 3<$1 4<$2
	umount vm_image
	rmdir vm_image/
	tar czf $3 *
	mv $3 ..
	rm *
	qemu-nbd -d /dev/nbd0
	cd ..
	rm -r patch
}

if [ "$#" -ne 10 ] && [ "$#" -ne 8 ] && [ "$#" -ne 6 ] && [ "$#" -ne 4 ];
then
	usage
	exit
fi

c_present=0
mp_present=0
src_present=0
dest=/mnt/spirent/ccpu/bin/
s_present=0
dest_present=0
while [ "$1" != ""  ]; do
	case $1 in
		-c )
			shift
			c_present=`expr 1 + $c_present`
			c_val=$1
			;;
		-mp )
			shift
			mp_present=`expr 1 + $mp_present`
			mp_val=$1
			;;
		-s ) 
			shift
			s_present=`expr 1 + $s_present`	
			slot_no=$1
			;;
		-src ) 
			shift 
			src_present=`expr 1 + $src_present`
			file_loc=$1
			;;
		-dest ) 
			shift
			dest_present=`expr 1 + $dest_present`
			dest=$1
			;;
		* ) 
			shift
			echo
			echo 'Error: Incorrect usage!!'
			usage
			exit
			;;
	esac
shift
done

if [ "$c_present" -ne 1 ] || [ "$mp_present" -ne 1 ];
then
	echo
	echo 'Error: Missing required parameters.'
	usage
	exit
fi

if [ "$c_val" -ne 0 ] && [ "$c_val" -ne 1 ];
then
	echo
	echo 'Error: Illegal values for -c. Possible values are 0 and 1 only.'
	usage
	exit
fi

if [ "$mp_val" -ne 0 ] && [ "$mp_val" -ne 1 ];
then
	echo
	echo 'Error: Illegal values for -mp. Possible values are 0 and 1 only.'
	usage
	exit
fi

if [ "$src_present" -eq 1 ] && [ ! -e "$file_loc" ];
then
	echo
	echo "Error: Source file doesn't exist! Exiting!!"
	echo
	exit
fi


if [ "$c_val" -eq 0 ];
then
	## If not patching chassis, need to make sure that user has provided a testmodule slot
	
	if [ "$src_present" -ne 1 ];
	then
		echo
		echo 'Error: Expecting a source file.'
		echo
		usage
		exit
	fi
	
	if [ "$s_present" -ne 1 ];
	then
		echo
		echo 'Error: Missing slot number to patch.'
		echo
		usage
		exit
	fi

	if [ "$mp_val" -eq 0 ];
	then
		echo "$file_loc" > $HOME/tmp.src
		file_loc=$HOME/tmp.src
		echo "$dest" > $HOME/tmp.dest
		dest=$HOME/tmp.dest
		chmod 7 "$file_loc"
		chmod 7 "$dest"

	elif [ "$dest_present" -ne 1 ];
	then
		echo
		echo 'Error: Missing list of destinations.'
		echo
		usage
		exit
	fi

	echo
	echo "Starting to patch..."
	echo
	echo -n "Number of files to patch: "
	src_count=$(wc -l < "$file_loc")
	echo "$src_count"
	echo
	echo -n "Number of destinations to patch: "
	dest_count=$(wc -l < "$dest")
	echo "$dest_count"
	echo

	if [ "$src_count" != "$dest_count" ];
	then
		echo
		echo "Error: Mismatch in number of sources and destinations."
		echo
		error_occured "$slot_no"
	fi

	src_file=$file_loc
	dest_file=$dest
	#make copy of folder to restore if error occurs
	mkdir $HOME/tmp.slot
	cp -r /mnt/spirent/testmodule/slot$slot_no/* $HOME/tmp.slot/
	prev_wd=$PWD
	#get all yocto images
	cd /mnt/spirent/testmodule/slot$slot_no
	find -name "yocto*" | cut -c 3- > $HOME/tmp.yocto
	yocto_file=$HOME/tmp.yocto
	chmod 7 "$yocto_file"
	echo -n "Number of yocto images found: "
	yocto_count=$(wc -l < "$yocto_file")
	echo "$yocto_count"
	echo

	if [ "$yocto_count" == '0' ];
	then
		echo
		echo "Error: No yocto image found to patch!"
		cd "$prev_wd"
		error_occured $slot_no
	fi

	cd "$prev_wd"
	#read yocto files and patch accordingly 
	while true
	do 
		read -r yocto_img <&3 || break
		# should always close open FDs before calling other functions because of inheritance
		##gotta call the respective function
		if [ "$yocto_img" == *"lxc"* ];
		then
			yocto_lxc "$src_file" "$dest_file" "$yocto_img" "$slot_no" "$prev_wd" 3<&-
		else
			yocto_non_lxc "$src_file" "$dest_file" "$yocto_img" "$slot_no" "$prev_wd" 3<&-
		fi
		# note that fd3 and fd4 are still open in the loop
	done 3<$yocto_file
	cleanup
	cd "$prev_wd" 	
	echo
	echo "Patching completed. Don't forget to powercycleslot or resetslot!"
	echo

else
	if [ "$s_present" -eq 1 ];
	then
		echo
		echo 'Error: Slot provided during chassis patch.'
		usage
		cleanup
		exit
	fi

	if [ "$mp_val" -eq 1 ] && [ "$src_present" -ne 1 ];
	then
		echo
		echo 'Error: Expecting source address of package.'
		usage
		cleanup
		exit
	fi

	##Need to shutdown daemons before patching the chassis.
	echo
	echo "Chassis patching: shutting down chassis components first ..."
	rsh chassis /usr/spirent/script/initscripts/sysmgr_i686 stop
	echo "done"
	echo "Deactivating chassis VM ..."
	pkgmgr deactivate all 0
	echo "done"
	echo
	echo "Starting to patch..."
	echo
		
	if [ "$mp_val" -eq 1 ] && [ "$src_present" -eq 1 ];
	then
		echo "Patching package $file_loc"
		echo
	fi

	if [ -e base.qcow2 ]; 
	then
		kill_nbd
		sync;sync
		sleep 2
		mkdir -p vm_image
		modprobe nbd max_part=63
		qemu-nbd -c /dev/nbd0 base.qcow2
		sleep 2
		mount /dev/nbd0p1 vm_image/
		
		if [ ! -z $dest ] && [ "$dest_present" -ne 0 ];
		then
			pushd vm_image/$dest > /dev/null 2>&1
			pret=$?
			echo "in dir `pwd`"
			echo "$file_loc/* ."
			cp $file_loc/* .
			sync

		elif [ "$mp_val" -eq 1 ] && [ "$src_present" -eq 1 ];
		then
			pushd vm_image > /dev/null 2>>/tmp/patch_vm.log
			tar xvzf $file_loc >> /tmp/patch_vm.log 2>&1
			popd > /dev/null 2>>/tmp/patch_vm.log
			umount vm_image
		else
			echo "No patch package specified."
			echo "Exiting for manual patching. Make sure to unmount vm_image after patching"
		fi

	else
		echo "Error: base.qcow2 of the VM to be patched is not there. Exiting!"
	fi

	if [ ! -z $dest ] && [ $pret -eq 0 ] && [ "$dest_present" -ne 0 ]; 
	then
		popd > /dev/null 2>&1
		umount vm_image
	fi
	echo
	echo "Patching completed for the chassis."
fi
