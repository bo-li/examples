! mc_lj_ll_module.f90
! Energy and move routines for MC, LJ potential, link-lists
MODULE mc_module

  USE, INTRINSIC :: iso_fortran_env, ONLY : output_unit, error_unit

  IMPLICIT NONE
  PRIVATE
  PUBLIC :: n, r
  PUBLIC :: introduction, conclusion, allocate_arrays, deallocate_arrays
  PUBLIC :: resize, energy_1, energy, energy_lrc
  PUBLIC :: move, create, destroy
  PUBLIC :: potovr

  INTEGER                              :: n ! number of atoms
  REAL,    DIMENSION(:,:), ALLOCATABLE :: r ! positions (3,:)
  INTEGER, DIMENSION(:),   ALLOCATABLE :: j_list ! list of j-neighbours

  INTEGER, PARAMETER :: lt = -1, gt = 1 ! Options for j-range
  REAL,    PARAMETER :: sigma = 1.0     ! Lennard-Jones diameter (unit of length)
  REAL,    PARAMETER :: epslj = 1.0     ! Lennard-Jones well depth (unit of energy)

  TYPE potovr ! A composite variable for interaction energies comprising
     REAL    :: pot ! the potential energy and
     REAL    :: vir ! the virial and
     LOGICAL :: ovr ! a flag indicating overlap (i.e. pot too high to use)
  END TYPE potovr

  INTERFACE OPERATOR (+)
     MODULE PROCEDURE add_potovr
  END INTERFACE OPERATOR (+)

CONTAINS

  FUNCTION add_potovr ( a, b ) RESULT (c)
    TYPE(potovr)             :: c    ! Result is the sum of the two inputs
    TYPE(potovr), INTENT(in) :: a, b
    c%pot = a%pot +    b%pot
    c%vir = a%vir +    b%vir
    c%ovr = a%ovr .OR. b%ovr
  END FUNCTION add_potovr

  SUBROUTINE introduction ( output_unit )
    INTEGER, INTENT(in) :: output_unit ! Unit for standard output

    WRITE ( unit=output_unit, fmt='(a)'           ) 'Lennard-Jones potential'
    WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'Diameter, sigma = ',     sigma    
    WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'Well depth, epsilon = ', epslj    
  END SUBROUTINE introduction

  SUBROUTINE conclusion ( output_unit )
    INTEGER, INTENT(in) :: output_unit ! Unit for standard output
    WRITE ( unit=output_unit, fmt='(a)') 'Program ends'
  END SUBROUTINE conclusion

  SUBROUTINE allocate_arrays ( box, r_cut )
    USE link_list_module, ONLY : initialize_list
    REAL, INTENT(in) :: box   ! Simulation box length
    REAL, INTENT(in) :: r_cut ! Potential cutoff distance

    REAL :: r_cut_box

    ALLOCATE ( r(3,n), j_list(n) )

    r_cut_box = r_cut / box
    IF ( r_cut_box > 0.5 ) THEN
       WRITE ( unit=error_unit, fmt='(a,f15.5)') 'r_cut/box too large ', r_cut_box
       STOP 'Error in allocate_arrays'
    END IF

    CALL initialize_list ( n, r_cut_box )

  END SUBROUTINE allocate_arrays

  SUBROUTINE deallocate_arrays
    USE link_list_module, ONLY : finalize_list
    DEALLOCATE ( r, j_list )
    CALL finalize_list
  END SUBROUTINE deallocate_arrays

  SUBROUTINE resize

    ! Reallocates r array, twice as large
    ! This is employed by mc_zvt_lj, grand canonical ensemble

    REAL, DIMENSION(:,:), ALLOCATABLE :: tmp
    INTEGER                           :: n_old, n_new

    n_old = SIZE(r,dim=2)
    n_new = 2*n_old
    WRITE( unit=output_unit, fmt='(a,i10,a,i10)' ) 'Reallocating r from old ', n_old, ' to ', n_new

    ALLOCATE ( tmp(3,n_new) ) ! New size for r
    tmp(:,1:n_old) = r(:,:)   ! Copy elements across

    CALL MOVE_ALLOC ( tmp, r )

  END SUBROUTINE resize

  FUNCTION energy ( box, r_cut )
    USE link_list_module, ONLY : make_list

    TYPE(potovr)      :: energy ! Returns a composite of pot, vir and ovr
    REAL, INTENT(in)  :: box    ! Simulation box length
    REAL, INTENT(in)  :: r_cut  ! Potential cutoff

    ! energy%pot is the nonbonded potential energy for whole system
    ! energy%vir is the corresponding virial for whole system
    ! energy%ovr is a flag indicating overlap (potential too high) to avoid overflow
    ! If this flag is .true., the values of energy%pot, energy%vir should not be used
    ! Actual calculation is performed by function energy_1

    TYPE(potovr)  :: energy_i
    INTEGER       :: i
    LOGICAL, SAVE :: first_call = .TRUE.

    IF ( n > SIZE(r,dim=2) ) THEN ! should never happen
       WRITE ( unit=error_unit, fmt='(a,2i15)' ) 'Array bounds error for r', n, SIZE(r,dim=2)
       STOP 'Error in energy'
    END IF
    IF ( first_call ) THEN
       r(:,:) = r(:,:) - ANINT ( r(:,:) ) ! Periodic boundaries
       CALL make_list ( n, r )
       first_call = .FALSE.
    END IF

    energy = potovr ( pot=0.0, vir=0.0, ovr=.FALSE. ) ! Initialize

    DO i = 1, n
       energy_i = energy_1 ( r(:,i), i, box, r_cut, gt )
       IF ( energy_i%ovr ) THEN
          energy%ovr = .TRUE. ! Overlap detected
          RETURN              ! Return immediately
       END IF
       energy = energy + energy_i
    END DO

    energy%ovr = .FALSE. ! No overlaps detected (redundant, but for clarity)

  END FUNCTION energy

  FUNCTION energy_1 ( ri, i, box, r_cut, j_range ) RESULT ( energy )
    TYPE(potovr)                    :: energy  ! Returns a composite of pot, vir and ovr
    REAL, DIMENSION(3), INTENT(in)  :: ri      ! Coordinates of atom of interest
    INTEGER,            INTENT(in)  :: i       ! Index of atom of interest
    REAL,               INTENT(in)  :: box     ! Simulation box length
    REAL,               INTENT(in)  :: r_cut   ! Potential cutoff distance
    INTEGER, OPTIONAL,  INTENT(in)  :: j_range ! Optional partner index range

    ! energy%pot is the nonbonded potential energy of atom ri with a set of other atoms
    ! energy%vir is the corresopnding virial of atom ri
    ! energy%ovr is a flag indicating overlap (potential too high) to avoid overflow
    ! If this is .true., the value of energy%pot should not be used
    ! The coordinates in ri are not necessarily identical with those in r(:,i)
    ! The optional argument j_range restricts partner indices to j>i, or j<i

    ! It is assumed that r has been divided by box
    ! Results are in LJ units where sigma = 1, epsilon = 1

    INTEGER            :: j, jj, nj
    LOGICAL            :: half
    REAL               :: r_cut_box, r_cut_box_sq, box_sq
    REAL               :: sr2, sr6, rij_sq
    REAL, DIMENSION(3) :: rij
    REAL, PARAMETER    :: sr2_overlap = 1.8 ! overlap threshold

    IF ( n > SIZE(r,dim=2) ) THEN ! should never happen
       WRITE ( unit=error_unit, fmt='(a,2i15)' ) 'Array bounds error for r', n, SIZE(r,dim=2)
       STOP 'Error in energy_1'
    END IF

    half = PRESENT ( j_range)
    CALL get_neighbours ( i, nj, half )

    r_cut_box    = r_cut / box
    r_cut_box_sq = r_cut_box**2
    box_sq       = box**2

    energy = potovr ( pot=0.0, vir= 0.0, ovr=.FALSE. ) ! Initialize

    DO jj = 1, nj
       j = j_list(jj)

       IF ( i == j ) CYCLE

       rij(:) = ri(:) - r(:,j)
       rij(:) = rij(:) - ANINT ( rij(:) ) ! periodic boundaries in box=1 units
       rij_sq = SUM ( rij**2 )

       IF ( rij_sq < r_cut_box_sq ) THEN

          rij_sq = rij_sq * box_sq ! now in sigma=1 units
          sr2 = 1.0 / rij_sq       ! (sigma/rij)**2

          IF ( sr2 > sr2_overlap ) THEN
             energy%ovr = .TRUE. ! Overlap detected
             RETURN              ! Return immediately
          END IF

          sr6 = sr2**3
          energy%pot = energy%pot + sr6**2 - sr6
          energy%vir = energy%vir + 2.0 * sr6**2 - sr6

       END IF

    END DO

    ! Numerical factors
    energy%pot = 4.0 * energy%pot 
    energy%vir = 24.0 * energy%vir
    energy%vir = energy%vir / 3.0

    energy%ovr = .FALSE. ! No overlaps detected (redundant but for clarity)

  END FUNCTION energy_1

  SUBROUTINE get_neighbours ( i, nj, half )
    USE link_list_module, ONLY : sc, list, head, c

    ! Arguments
    INTEGER, INTENT(in)  :: i  ! particle whose neighbours are required
    LOGICAL, INTENT(in)  :: half ! determining the range of neighbours searched
    INTEGER, INTENT(out) :: nj ! number of j-partners

    ! Set up vectors to each cell in neighbourhood of 3x3x3 cells in cubic lattice
    INTEGER, PARAMETER :: nk = 13 
    INTEGER, DIMENSION(3,-nk:nk), PARAMETER :: d = RESHAPE( [ &
         &   -1,-1,-1,    0,-1,-1,    1,-1,-1, &
         &   -1, 1,-1,    0, 1,-1,    1, 1,-1, &
         &   -1, 0,-1,    1, 0,-1,    0, 0,-1, &
         &    0,-1, 0,    1,-1, 0,   -1,-1, 0, &
         &   -1, 0, 0,    0, 0, 0,    1, 0, 0, &
         &    1, 1, 0,   -1, 1, 0,    0, 1, 0, &
         &    0, 0, 1,   -1, 0, 1,    1, 0, 1, &
         &   -1,-1, 1,    0,-1, 1,    1,-1, 1, &
         &   -1, 1, 1,    0, 1, 1,    1, 1, 1    ], [ 3, 2*nk+1 ] )

    ! Local variables
    INTEGER :: k1, k2, k, j
    INTEGER, DIMENSION(3) :: cj

    IF ( half ) THEN ! check half neighbour cells and j downlist from i in current cell
       k1 = 0
       k2 = nk
    ELSE ! check every atom other than i in all cells
       k1 = -nk
       k2 =  nk
    END IF

    nj = 0 ! Will store number of neighbours found

    DO k = k1, k2 ! Begin loop over neighbouring cells

       cj(:) = c(:,i) + d(:,k)      ! Neighbour cell index
       cj(:) = MODULO ( cj(:), sc ) ! Periodic boundary correction

       IF ( k == 0 .AND. half ) THEN
          j = list(i) ! check down-list from i in i-cell
       ELSE
          j = head(cj(1),cj(2),cj(3)) ! check entire j-cell
       END IF

       DO ! Begin loop over j atoms in list

          IF ( j == 0 ) EXIT

          IF ( j /= i ) THEN
             nj         = nj + 1 ! increment count of j atoms
             j_list(nj) = j      ! store new j atom
          END IF
          j = list(j) ! Next atom in j cell

       ENDDO ! End loop over j atoms in list

    ENDDO ! End loop over neighbouring cells 

  END SUBROUTINE get_neighbours

  SUBROUTINE energy_lrc ( n, box, r_cut, pot, vir )
    INTEGER, INTENT(in)  :: n        ! number of atoms
    REAL,    INTENT(in)  :: box      ! simulation box length
    REAL,    INTENT(in)  :: r_cut    ! cutoff distance
    REAL,    INTENT(out) :: pot, vir ! potential and virial

    ! Calculates long-range corrections for Lennard-Jones potential and virial
    ! These are the corrections to the total values
    ! r_cut, box, and the results, are in LJ units where sigma = 1, epsilon = 1

    REAL               :: sr3, density
    REAL, PARAMETER    :: pi = 4.0 * ATAN(1.0)

    sr3 = ( 1.0 / r_cut ) ** 3
    pot = (8.0/9.0)  * sr3**3  -(8.0/3.0)  * sr3
    vir = (32.0/9.0) * sr3**3  -(32.0/6.0) * sr3

    density =  REAL(n) / box**3
    pot     = pot * pi * density * REAL(n)
    vir     = vir * pi * density * REAL(n)

  END SUBROUTINE energy_lrc

  SUBROUTINE move ( i, ri )
    USE link_list_module, ONLY : c_index, move_in_list
    INTEGER,               INTENT(in) :: i
    REAL,    DIMENSION(3), INTENT(in) :: ri

    INTEGER, DIMENSION(3) :: ci

    r(:,i) = ri                ! New position
    ci(:)  = c_index ( ri(:) ) ! New cell index
    CALL move_in_list ( i, ci(:) )

  END SUBROUTINE move

  SUBROUTINE create ( ri )
    USE link_list_module, ONLY : c_index, create_in_list
    REAL, DIMENSION(3), INTENT(in) :: ri

    INTEGER, DIMENSION(3) :: ci

    n      = n+1               ! increase number of atoms
    r(:,n) = ri(:)             ! add new atom at the end
    ci(:)  = c_index ( ri(:) ) ! New cell index
    CALL create_in_list ( n, ci )

  END SUBROUTINE create

  SUBROUTINE destroy ( i )
    USE link_list_module, ONLY : destroy_in_list, move_in_list, c
    INTEGER, INTENT(in) :: i

    r(:,i) = r(:,n) ! replace atom i coordinates with atom n
    CALL destroy_in_list ( n, c(:,n) )
    CALL move_in_list ( i, c(:,n) )
    n = n - 1  ! reduce number of atoms

  END SUBROUTINE destroy

END MODULE mc_module
