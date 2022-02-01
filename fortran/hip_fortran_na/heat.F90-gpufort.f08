#ifdef __GPUFORT
#include "heat.F90-fort2hip.f08"
#endif
module run
#ifdef __GPUFORT
   use hipfort
   use hipfort_check
#else
   use cudafor
#endif
   use mpi

   implicit none

   integer, parameter :: doubtype = selected_real_kind(15, 307)  ! double precision

   integer, parameter :: mykind = doubtype
   integer, parameter :: mpi_prec = mpi_real8

#ifdef __GPUFORT
   real, pointer, dimension(:, :) :: t_d
   real, pointer, dimension(:, :) :: t_old_d
#else
   real, allocatable, dimension(:, :) :: T_d, T_old_d
#endif
   real, allocatable, dimension(:, :) :: T
   real, allocatable, dimension(:, :) :: t_1s, t_2s, t_1r, t_2r
#ifdef __GPUFORT
   real, pointer, dimension(:, :) :: td_1s
   real, pointer, dimension(:, :) :: td_2s
   real, pointer, dimension(:, :) :: td_1r
   real, pointer, dimension(:, :) :: td_2r
#else
   real, allocatable, dimension(:, :) :: td_1s, td_2s, td_1r, td_2r
#endif
   real, allocatable, dimension(:)   :: x, y
   real, allocatable, dimension(:)   :: xg

   integer    :: n, ntime
   real   :: dom_len, delta, dt, nu, sigma
   !gpufort bug
   real :: r
   ! If solution file needs to be printed
   integer :: soln
   integer    :: iercuda

   !MPI
   integer, parameter :: ndims = 1
   integer, dimension(:), allocatable  :: nblocks
   logical, dimension(:), allocatable  :: pbc
   integer, dimension(mpi_status_size) :: istatus

   integer, dimension(:), allocatable :: ncoords
   integer :: mp_cart, mp_cartx
   integer :: nrank, nproc, nrank_x
   integer :: ileftx, irightx
   integer :: iermpi, local_comm, mydev

   integer :: nx
   integer :: ny
   integer, parameter :: ng = 1   ! Number of ghost nodes
   logical :: masterproc

#ifndef __GPUFORT
   attributes(device) :: T_d, T_old_d
   attributes(device) :: td_1s, td_2s, td_1r, td_2r
#endif

end module

module mod_setup
contains
   subroutine setup()
      use run
      implicit none

      integer :: dims(1), i, j, k, ii, jj
      logical :: reord, remain_dims(ndims)

      call mpi_init(iermpi)
      call mpi_comm_rank(mpi_comm_world, nrank, iermpi)
      call mpi_comm_size(mpi_comm_world, nproc, iermpi)

      mydev = 0
      call mpi_comm_split_type(mpi_comm_world, mpi_comm_type_shared, 0, mpi_info_null, local_comm, iermpi)
      call mpi_comm_rank(local_comm, mydev, iermpi)
#ifdef __GPUFORT
      iermpi = hipSetDevice(mydev)
#else
      iermpi = cudaSetDevice(mydev)
#endif
      write (*, *) "MPI rank", nrank, "using GPU", mydev

      allocate (ncoords(ndims))
      allocate (nblocks(ndims))
      allocate (pbc(ndims))

      pbc(1) = .false.

      masterproc = .false.
      if (nrank == 0) masterproc = .true.

      open (unit=11, file='input.dat', form='formatted')

      read (11, *) n, sigma, nu, dom_len, ntime, soln

      close (11)

      dims = [0]
      call MPI_Dims_create(nproc, 1, dims, iermpi)
      nblocks(1) = dims(1)
      if (masterproc) write (*, *) 'Automatic MPI decomposition:', nblocks(1), ' x 1'

      nx = n/nblocks(1)
      ny = n/1

      reord = .false.

      call mpi_cart_create(mpi_comm_world, ndims, nblocks, pbc, reord, mp_cart, iermpi)
      call mpi_cart_coords(mp_cart, nrank, ndims, ncoords, iermpi)

      remain_dims(1) = .true.
      call mpi_cart_sub(mp_cart, remain_dims, mp_cartx, iermpi)
      call mpi_comm_rank(mp_cartx, nrank_x, iermpi)
      call mpi_cart_shift(mp_cartx, 0, 1, ileftx, irightx, iermpi)

! Allocate variables

      allocate (T(1 - ng:nx + ng, 1 - ng:ny + ng))
      allocate (x(1 - ng:nx + ng))
      allocate (y(1 - ng:ny + ng))
#ifdef __GPUFORT
      call hipCheck(hipMalloc(T_d, (nx + ng) - ((1 - ng)) + 1, (ny + ng) - ((1 - ng)) + 1))
      call hipCheck(hipMalloc(T_old_d, (nx + ng) - ((1 - ng)) + 1, (ny + ng) - ((1 - ng)) + 1))
#else
      allocate (T_d(1 - ng:nx + ng, 1 - ng:ny + ng))
      allocate (T_old_d(1 - ng:nx + ng, 1 - ng:ny + ng))
#endif

      allocate (t_1s(ng, ny))
      allocate (t_2s(ng, ny))
      allocate (t_1r(ng, ny))
      allocate (t_2r(ng, ny))
      !
#ifdef __GPUFORT
      call hipCheck(hipMalloc(td_1s, ng, ny))
      call hipCheck(hipMalloc(td_2s, ng, ny))
      call hipCheck(hipMalloc(td_1r, ng, ny))
      call hipCheck(hipMalloc(td_2r, ng, ny))
#else
      allocate (td_1s(ng, ny))
      allocate (td_2s(ng, ny))
      allocate (td_1r(ng, ny))
      allocate (td_2r(ng, ny))
#endif
      !
      allocate (xg(1 - ng:n + ng))

      delta = dom_len/real(n - 1)

      dt = (sigma*delta**2)/nu

      r = (nu*dt)/delta**2

      do i = 1 - ng, n + ng
         xg(i) = (i - 1)*delta
      end do
      ii = nx*ncoords(1)
      do i = 1 - ng, nx + ng
         x(i) = xg(ii + i)
      end do
      y = xg

   end subroutine
end module

module mod_swap
contains
   subroutine swap()
#ifdef __GPUFORT
      use mod_swap_fort2hip
#endif
      use run
      implicit none
      integer :: i, j
      integer :: indx, indy
      type(dim3) :: grid, tBlock

      indx = ng*ny

      tBlock = dim3(128, 2, 1)
      grid = dim3(ceiling(real(ng - (1) + 1))/tBlock%x, ceiling(real(ny - (1) + 1))/tBlock%y, 1)
#ifdef __GPUFORT
      ! extracted to HIP C++ file
      call launch_swap_153_c8dc21(grid, tBlock, 0, c_null_ptr, c_loc(td_1s), size(td_1s, 1), size(td_1s, 2), lbound(td_1s, 1), lbound(td_1s, 2), c_loc(t_d), size(t_d, 1), size(t_d, 2), lbound(t_d, 1), lbound(t_d, 2), c_loc(td_2s), size(td_2s, 1), size(td_2s, 2), lbound(td_2s, 1), lbound(td_2s, 2), nx, ng, ny)
#else
      !$cuf kernel do(2)<<<grid,tBlock>>>
      do j = 1, ny
         do i = 1, ng
            td_1s(i, j) = T_d(i, j)
            td_2s(i, j) = T_d(nx - ng + i, j)
         end do
      end do
#endif
      !@cuf iercuda=cudaDeviceSynchronize()

#ifdef __GPUFORT
      call hipCheck(hipMemcpy(t_1s, td_1s, hipMemcpyDeviceToHost))
      call hipCheck(hipMemcpy(t_2s, td_2s, hipMemcpyDeviceToHost))
#else
      t_1s = td_1s
      t_2s = td_2s
#endif
      call mpi_sendrecv(t_1s, indx, mpi_prec, ileftx, 1, t_2r, indx, mpi_prec, irightx, 1, mp_cartx, istatus, iermpi)
      call mpi_sendrecv(t_2s, indx, mpi_prec, irightx, 2, t_1r, indx, mpi_prec, ileftx, 2, mp_cartx, istatus, iermpi)
#ifdef __GPUFORT
      call hipCheck(hipMemcpy(td_1r, t_1r, hipMemcpyHostToDevice))
      call hipCheck(hipMemcpy(td_2r, t_2r, hipMemcpyHostToDevice))
#else
      td_1r = t_1r
      td_2r = t_2r
#endif

      if (ileftx /= mpi_proc_null) then
#ifdef __GPUFORT
         ! extracted to HIP C++ file
         call launch_swap_170_d45ddb(grid, tBlock, 0, c_null_ptr, c_loc(t_d), size(t_d, 1), size(t_d, 2), lbound(t_d, 1), lbound(t_d, 2), ng, c_loc(td_1r), size(td_1r, 1), size(td_1r, 2), lbound(td_1r, 1), lbound(td_1r, 2), ny)
#else
         !$cuf kernel do(2)<<<grid,tBlock>>>
         do j = 1, ny
            do i = 1, ng
               T_d(i - ng, j) = td_1r(i, j)
            end do
         end do
#endif
         !@cuf iercuda=cudaDeviceSynchronize()
      end if
      if (irightx /= mpi_proc_null) then
#ifdef __GPUFORT
         ! extracted to HIP C++ file
         call launch_swap_179_b0e0a8(grid, tBlock, 0, c_null_ptr, c_loc(t_d), size(t_d, 1), size(t_d, 2), lbound(t_d, 1), lbound(t_d, 2), nx, c_loc(td_2r), size(td_2r, 1), size(td_2r, 2), lbound(td_2r, 1), lbound(td_2r, 2), ng, ny)
#else
         !$cuf kernel do(2)<<<grid,tBlock>>>
         do j = 1, ny
            do i = 1, ng
               T_d(nx + i, j) = td_2r(i, j)
            end do
         end do
#endif
         !@cuf iercuda=cudaDeviceSynchronize()
      end if

   end subroutine

end module

module mod_heat
contains
   subroutine heat_eqn()
#ifdef __GPUFORT
      use mod_heat_fort2hip
#endif
      use run
      use mod_swap
      implicit none
      integer    :: i, j, k
      type(dim3) :: grid, tBlock

      ! Time loop
      do i = 1, ntime
         if (masterproc) write (*, *) "time_it:", i
#ifdef __GPUFORT
         call hipCheck(hipMemcpy(T_old_d, T_d, hipMemcpyDeviceToDevice))
#else
         T_old_d = T_d
#endif
         tBlock = dim3(32, 4, 1)
         grid = dim3(ceiling(real(ny)/tBlock%x), ceiling(real(nx)/tBlock%y), 1)
#ifdef __GPUFORT
         ! extracted to HIP C++ file
         call launch_heat_eqn_207_25f1bf(grid, tBlock, 0, c_null_ptr, c_loc(t_d), size(t_d, 1), size(t_d, 2), lbound(t_d, 1), lbound(t_d, 2), c_loc(t_old_d), size(t_old_d, 1), size(t_old_d, 2), lbound(t_old_d, 1), lbound(t_old_d, 2), r, ny, nx)
#else
         !$cuf kernel do(2)<<<grid,tBlock>>>
         do j = 1, nx
            do k = 1, ny
               T_d(j, k) = T_old_d(j, k) + r*(T_old_d(j + 1, k) + T_old_d(j, k + 1) + T_old_d(j - 1, k) + T_old_d(j, k - 1) - 4*T_old_d(j, k))
            end do
         end do
#endif
         !@cuf iercuda=cudaDeviceSynchronize()

         ! Ghost update
         !call swap()
      end do

   end subroutine

end module

program heat
   use run
   use mod_heat
   use mod_setup

   implicit none

   integer ::  i, j, k, z
   real :: start, finish, lsum, gsum
   character(len=8) :: fmt, x1

   call setup()

! Setting initial and boundary conditions
   T = 2.0
   if (ileftx == mpi_proc_null) then
      T(1 - ng, :) = 1.0
   end if
   if (irightx == mpi_proc_null) then
      T(nx + ng, :) = 1.0
   end if
   T(:, 1 - ng) = 1.0
   T(:, ny + ng) = 1.0

   call MPI_BARRIER(mpi_comm_world, iermpi)
   call cpu_time(start)

   if (masterproc) print *, "nx: ", nx, "ny: ", ny
!
   ! Host to device
#ifdef __GPUFORT
   call hipCheck(hipMemcpy(T_d, T, hipMemcpyHostToDevice))
#else
   T_d = T
#endif

   call heat_eqn()
!
   ! Back to host
#ifdef __GPUFORT
   call hipCheck(hipMemcpy(T, T_d, hipMemcpyDeviceToHost))
#else
   T = T_d
#endif

   call MPI_BARRIER(mpi_comm_world, iermpi)
   call cpu_time(finish)

   lsum = 0.0
   do i = 1, nx
      do j = 1, ny
         lsum = lsum + T(i, j)
      end do
   end do
   call MPI_Reduce(lsum, gsum, 1, MPI_DOUBLE, MPI_SUM, 0, mpi_comm_world, iermpi)

   if (masterproc) print *, "Sum of Temperature:", gsum

   if (soln == 1) then
      fmt = '(I5.5)'

      write (x1, fmt) nrank
      open (unit=17, file='soln'//trim(x1)//'.dat', form='formatted')
      do i = 1, nx
         do j = 1, ny
            write (17, *) x(i), y(j), T(i, j)
         end do
      end do
      close (17)
   end if

!
   if (masterproc) print *, "simulation completed!!!!"
   if (masterproc) print *, "total time:", finish - start

   deallocate (x, y)
#ifdef __GPUFORT
   call hipCheck(hipFree(T_d))
   call hipCheck(hipFree(T_old_d))
   deallocate (T)
#else
   deallocate (T, T_d, T_old_d)
#endif
   deallocate (t_1s, t_2s, t_1r, t_2r)
#ifdef __GPUFORT
   call hipCheck(hipFree(td_1s))
   call hipCheck(hipFree(td_2s))
   call hipCheck(hipFree(td_1r))
   call hipCheck(hipFree(td_2r))
#else
   deallocate (td_1s, td_2s, td_1r, td_2r)
#endif
   deallocate (xg)
   deallocate (ncoords, nblocks, pbc)

   call mpi_finalize(iermpi)

end program
