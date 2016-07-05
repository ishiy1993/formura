program main
  implicit none

  integer, parameter :: sx = 640, sy = 480
  double precision, dimension (sx,sy) :: screen
  double precision, parameter :: ox = 320, oy = 240
  integer :: file_unit
  integer :: x,y


!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  ! main program
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  do y = 1, sy
     do x = 1, sx
        screen(x,y) = (x-ox) ** 2 + (y-oy) ** 2
     end do
  end do

  file_unit = get_file_unit()
  open(file_unit, file='test.bin', status='replace', access='stream')
  write(file_unit), sx,sy
  write(file_unit) screen
  close(file_unit)


contains
  ! http://fortranwiki.org/fortran/show/newunit
  integer function get_file_unit()
    integer, parameter :: LUN_MIN=10, LUN_MAX=1000
    logical :: opened
    integer :: lun

    get_file_unit=-1
    do lun=LUN_MIN,LUN_MAX
       inquire(unit=lun,opened=opened)
       if (.not. opened) then
          get_file_unit=lun
          exit
       end if
    end do
  end function get_file_unit

end program main
