"""Campus authentication providers."""

from .dorm_drcom import DormDrcomProvider
from .teaching_srun import TeachingSRunProvider

__all__ = ["DormDrcomProvider", "TeachingSRunProvider"]
