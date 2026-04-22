// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ISubjectLifecycleSync {
    function syncSubjectLifecycle(bool active_, bool retiring_) external;
}
