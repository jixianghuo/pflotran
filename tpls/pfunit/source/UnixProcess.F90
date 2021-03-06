!-------------------------------------------------------------------------------
! NASA/GSFC, Software Integration & Visualization Office, Code 610.3
!-------------------------------------------------------------------------------
!  MODULE: UnixProcess
!
!> @brief
!! <BriefDescription>
!!
!! @author
!! Tom Clune,  NASA/GSFC 
!!
!! @date
!! 07 Nov 2013
!! 
!! @note <A note here.>
!! <Or starting here...>
!
! REVISION HISTORY:
!
! 07 Nov 2013 - Added the prologue for the compliance with Doxygen. 
!
!-------------------------------------------------------------------------------
! This module encapsulates the ability to issue background system commands
! Unix pipes are used under the hood soo that results from such commands
! can be returned to the program for further processing.
! One can also check to see if the process has terminated, or optionally terminate
! the process.
!
! This is needed by the framework to manage a separate exeuctable that
! can be monitored for actual crashes as opposed to mere Assert
! failures.
!
! Although Fortran 2008 introduces the ability to spawn a process, it
! still provides no ability to return data directly back to the
! Fortran program.  So, with much regret, this module represents a bit
! of a departure from standard conforming Fortran.  It should be
! portable on any Unix system, and easily adapted to Windows by
! someone with relevant expertise.
#include "pFUnit_compiler_kludges.H90"

module UnixProcess_mod
   use, intrinsic :: iso_c_binding
   implicit none
   private

   public :: UnixProcess
#ifdef Intel
   public :: execute_command_line
#endif
   

   type UnixProcess
      private
      type (C_PTR) :: file = C_NULL_PTR
      integer :: pid = -1
   contains
      procedure :: getLine
      procedure :: getDelim
      procedure :: isActive
      procedure :: terminate
      procedure :: getPid
   end type UnixProcess

   interface UnixProcess
      module procedure newProcess
   end interface UnixProcess

contains

   function newProcess(command, runInBackground) result(process)
      use UnixPipeInterfaces_mod, only: popen, getLine
      use StringConversionUtilities_mod, only: nullTerminate
      use, intrinsic :: iso_c_binding, only: C_PTR
      use Assert_mod
      type (UnixProcess) :: process
      character(len=*), intent(in) :: command
      logical, optional, intent(in) :: runInBackground

      character(len=:), allocatable :: fullCommand
      character(len=:), allocatable :: mode

!      type (C_PTR) :: fileHandle
!      type (C_PTR) :: line
!      integer :: pid
      integer, parameter :: MAX_LEN = 80
      character(len=:), allocatable :: string
!      integer :: rc
!      integer :: i

      fullCommand = makeCommand(command, runInBackground)
      mode = nullTerminate('r')

      process%file = popen(fullCommand, mode)
      call assertTrue(c_associated(process%file))

      if (present(runInBackground)) then
         if (runInBackground) then
            string = process%getLine()
            read(string,*) process%pid
         else
            process%pid = -1
         end if
      end if

   end function newProcess

   ! Background commands must return a PID for further interactions.
   ! Also commands need to be null-terminated to send to C procedures.
   function makeCommand(baseCommand, runInBackground) result(command)
      use StringConversionUtilities_mod, only: nullTerminate
      character(len=:), allocatable :: command
      character(len=*), intent(in) :: baseCommand
      logical, optional, intent(in) :: runInBackground

      logical :: runInBackground_

      runInBackground_ = .false.
      if (present(runInBackground)) runInBackground_ = runInBackground

      command = baseCommand
      if (runInBackground_) then
         command = command // '& echo $!'
      end if
      command = nullTerminate(command)
   end function makeCommand

   logical function isActive(this)
      class (UnixProcess), intent(in) :: this
      
      integer, parameter :: MAX_LEN = 40
      character(len=MAX_LEN) :: command
      integer :: stat, cstat

      if (this%pid >=0) then
         write(command, '("kill -0 ",i0," > /dev/null 2>&1")') this%pid
         call execute_command_line(command, exitStat=stat, cmdStat=cstat)
         isActive = (stat == 0)
      else
         isActive = .false.
      end if

   end function isActive

   subroutine terminate(this)
      class (UnixProcess), intent(inout) :: this

      integer, parameter :: MAX_LEN = 120
      character(len=MAX_LEN) :: command
      integer :: stat, cstat

      if (this%pid >=0) then
         write(command,'(a,i0,a)') "kill -15 `ps -ef 2> /dev/null | awk '$3 == ",this%pid," {print $2}'` > /dev/null 2>&1" 
         call execute_command_line(command, exitStat=stat, cmdStat=cstat)
         write(command, '("kill -15 ",i0," > /dev/null 2>&1; ")') this%pid
         call execute_command_line(command, exitStat=stat, cmdStat=cstat)
      end if

   end subroutine terminate

   function getLine(this) result(line)
      use UnixPipeInterfaces_mod, only: c_getLine => getLine
      use UnixPipeInterfaces_mod, only: free
      class (UnixProcess) :: this
#ifdef GFORTRAN_4_7
      character(len=PFUNIT_LINE_LENGTH) :: line
#else
      character(len=:), allocatable :: line
#endif

      type (C_PTR) :: pBuffer
      integer, parameter :: MAX_BUFFER_SIZE = 100000
      character(len=MAX_BUFFER_SIZE), pointer :: buffer
      integer (kind=C_SIZE_T) :: length
      integer (kind=C_SIZE_T) :: rc
!      integer :: i

!!$      line = this%getDelim(new_line('$'))

      pBuffer = C_NULL_PTR
      rc = c_getline(pBuffer, length, this%file)
      if (length >= MAX_BUFFER_SIZE) then
         print*,'Error - need to increase MAX_BUFFER_SIZE in UnixProcess::getLine().'
      end if

      call c_f_pointer(pBuffer, buffer)
      ! drop newline and delimeter
      line = buffer(1:rc-1)

      call free(pBuffer)

   end function getLine

   function getDelim(this, delimeter) result(line)
      use UnixPipeInterfaces_mod, only: c_getDelim => getDelim
      use UnixPipeInterfaces_mod, only: free
#ifdef GFORTRAN_4_7
      character(len=PFUNIT_LINE_LENGTH) :: line
#else
      character(len=:), allocatable :: line
#endif
      class (UnixProcess) :: this
      character(len=C_CHAR), intent(in) :: delimeter

      type (C_PTR) :: pBuffer
      integer, parameter :: MAX_BUFFER_SIZE = 100000
      character(len=MAX_BUFFER_SIZE), pointer :: buffer
      integer (kind=C_SIZE_T) :: length
      integer (kind=C_SIZE_T) :: rc
!      integer :: i

      integer(kind=C_INT) :: useDelimeter


      pBuffer = C_NULL_PTR
      useDelimeter = ichar(delimeter)
      rc = c_getdelim(pBuffer, length, useDelimeter, this%file)
      if (length >= MAX_BUFFER_SIZE) then
         print*,'Error - need to increase MAX_BUFFER_SIZE in UnixProcess::getLine().'
      end if

      call c_f_pointer(pBuffer, buffer)
      ! drop newline and delimeter
      line = buffer(1:rc-1)

      call free(pBuffer)

   end function getDelim

   integer function getPid(this) result(pid)
      class (UnixProcess), intent(in) :: this
      pid = this%pid
   end function getPid


#ifdef Intel
   subroutine execute_command_line(command, exitStat, cmdStat)
      use ifport
      character(len=*), intent(in) :: command
      integer, optional, intent(out) :: exitStat
      integer, optional, intent(out) :: cmdStat

      integer :: exitStat_

      exitStat_ = system(trim(command))
      if (present(exitStat)) exitStat = exitStat_
      if (present(cmdStat)) cmdStat = 0

   end subroutine execute_command_line
#endif
   
end module UnixProcess_mod
