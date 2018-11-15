# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.

function Run_Dpdk_TestPmd {
	$testJob = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username $superUser -password $password -command "./StartDpdkTestPmd.sh" -RunInBackground

	#region MONITOR TEST
	while ((Get-Job -Id $testJob).State -eq "Running") {
		$currentStatus = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username $superUser -password $password -command "tail -2 dpdkConsoleLogs.txt | head -1"
		LogMsg "Current Test Status : $currentStatus"
		WaitFor -seconds 20
	}
	$finalStatus = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username $superUser -password $password -command "cat /root/state.txt"
	RemoteCopy -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username $superUser -password $password -download -downloadTo $currentDir -files "*.csv, *.txt, *.log"

	if ($finalStatus -imatch "TestFailed") {
		LogErr "Test failed. Last known status : $currentStatus."
		$testResult = "FAIL"
	}
	elseif ($finalStatus -imatch "TestAborted") {
		LogErr "Test Aborted. Last known status : $currentStatus."
		$testResult = "ABORTED"
	}
	elseif ($finalStatus -imatch "TestCompleted") {
		LogMsg "Test Completed."
		$testResult = "PASS"
		RemoteCopy -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username $superUser -password $password -download -downloadTo $currentDir -files "*.tar.gz"
	}
	elseif ($finalStatus -imatch "TestRunning") {
		LogMsg "Powershell backgroud job for test is completed but VM is reporting that test is still running. Please check $LogDir\zkConsoleLogs.txt"
		LogMsg "Contests of summary.log : $testSummary"
		$testResult = "PASS"
    }

	if ($testResult -eq "PASS") {
		return $true
	} else {
		return $false
	}
}
function Main {
    # Create test result
    $superUser = "root"
    $resultArr = @()
    $lowerbound = 1000000
    try {
        $noClient = $true
        $noServer = $true
        foreach ($vmData in $allVMData) {
            if ($vmData.RoleName -imatch "client") {
                $clientVMData = $vmData
                $noClient = $false
            }
            elseif ($vmData.RoleName -imatch "server") {
                $noServer = $false
                $serverVMData = $vmData
            } else {
                LogErr "VM role name is not matched with server or client"
            }
        }
        if ($noClient) {
            Throw "No any master VM defined. Be sure that, Client VM role name matches with the pattern `"*master*`". Aborting Test."
        }
        if ($noServer) {
            Throw "No any slave VM defined. Be sure that, Server machine role names matches with pattern `"*slave*`" Aborting Test."
        }
        #region CONFIGURE VM FOR TERASORT TEST
        LogMsg "CLIENT VM details :"
        LogMsg "  RoleName : $($clientVMData.RoleName)"
        LogMsg "  Public IP : $($clientVMData.PublicIP)"
        LogMsg "  SSH Port : $($clientVMData.SSHPort)"
        LogMsg "  Internal IP : $($clientVMData.InternalIP)"
        LogMsg "SERVER VM details :"
        LogMsg "  RoleName : $($serverVMData.RoleName)"
        LogMsg "  Public IP : $($serverVMData.PublicIP)"
        LogMsg "  SSH Port : $($serverVMData.SSHPort)"
        LogMsg "  Internal IP : $($serverVMData.InternalIP)"

        # PROVISION VMS FOR LISA WILL ENABLE ROOT USER AND WILL MAKE ENABLE PASSWORDLESS AUTHENTICATION ACROSS ALL VMS IN SAME HOSTED SERVICE.
        ProvisionVMsForLisa -allVMData $allVMData -installPackagesOnRoleNames "none"
        #endregion

        LogMsg "Getting Active NIC Name."
        $getNicCmd = ". ./utils.sh &> /dev/null && get_active_nic_name"
        $clientNicName = (RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username $superUser -password $password -command $getNicCmd).Trim()
        $serverNicName = (RunLinuxCmd -ip $clientVMData.PublicIP -port $serverVMData.SSHPort -username $superUser -password $password -command $getNicCmd).Trim()
        if ($serverNicName -eq $clientNicName) {
            LogMsg "Client and Server VMs have same nic name: $clientNicName"
        } else {
            Throw "Server and client SRIOV NICs are not same."
        }
        if($EnableAcceleratedNetworking -or ($currentTestData.AdditionalHWConfig.Networking -imatch "SRIOV")) {
            $DataPath = "SRIOV"
        } else {
            $DataPath = "Synthetic"
        }
        LogMsg "CLIENT $DataPath NIC: $clientNicName"
        LogMsg "SERVER $DataPath NIC: $serverNicName"

        LogMsg "Generating constansts.sh ..."
        $constantsFile = "$LogDir\constants.sh"
        Set-Content -Value "#Generated by Azure Automation." -Path $constantsFile
        Add-Content -Value "vms=$($serverVMData.RoleName),$($clientVMData.RoleName)" -Path $constantsFile
        Add-Content -Value "server=$($serverVMData.InternalIP)" -Path $constantsFile
        Add-Content -Value "client=$($clientVMData.InternalIP)" -Path $constantsFile
        Add-Content -Value "nicName=eth1" -Path $constantsFile
        Add-Content -Value "pciAddress=0002:00:02.0" -Path $constantsFile

        foreach ($param in $currentTestData.TestParameters.param) {
            Add-Content -Value "$param" -Path $constantsFile
            if ($param -imatch "modes") {
                $modes = ($param.Replace("modes=",""))
            }
        }
        LogMsg "constanst.sh created successfully..."
        LogMsg "test modes : $modes"
        LogMsg (Get-Content -Path $constantsFile)
        #endregion

        #region EXECUTE TEST
        $myString = @"
cd /root/
./dpdkTestPmd.sh 2>&1 > dpdkConsoleLogs.txt
. utils.sh
collect_VM_properties
"@
        Set-Content "$LogDir\StartDpdkTestPmd.sh" $myString
        RemoteCopy -uploadTo $clientVMData.PublicIP -port $clientVMData.SSHPort -files ".\$constantsFile,.\$LogDir\StartDpdkTestPmd.sh" -username $superUser -password $password -upload
		$null = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username $superUser -password $password -command "chmod +x *.sh" | Out-Null

		$currentDir = "$LogDir\initialSRIOVTest"
		New-Item -Path $currentDir -ItemType Directory | Out-Null
        $initailTest = Run_Dpdk_TestPmd
		if ($initailTest -eq $true) {
            $initialSriovResult = Import-Csv -Path $currentDir\dpdkTestPmd.csv
			LogMsg ($initialSriovResult | Format-Table | Out-String)
			$testResult = "PASS"
		} else {
			$testResult = "FAIL"
			LogErr "Initial DPDK test execution failed"
		}
		$resultArr += $testResult
		$currentTestResult.TestSummary +=  CreateResultSummary -testResult "$($initialSriovResult.DpdkVersion) : TxPPS : $($initialSriovResult.TxPps) : RxPPS : $($initialSriovResult.RxPps)" -metaData "DPDK-TESTPMD : Initial SRIOV" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName

        #disable SRIOV
        $sriovStatus = $false
        $currentDir = "$LogDir\syntheticTest"
		New-Item -Path $currentDir -ItemType Directory | Out-Null
        $sriovStatus = Set-SRIOVInVMs -VirtualMachinesGroupName $AllVMData.ResourceGroupName[0] -Disable
		$clientVMData.PublicIP = $AllVMData.PublicIP[0]
		if ($sriovStatus -eq $true) {
			LogMsg "SRIOV is disabaled"
			$syntheticTest = Run_Dpdk_TestPmd
			if ($syntheticTest -eq $true){
                $syntheticResult = Import-Csv -Path $currentDir\dpdkTestPmd.csv
				LogMsg ($syntheticResult | Format-Table | Out-String)
				$testResult = "PASS"
			} else {
				$testResult = "FAIL"
				LogErr "Synthetic DPDK test execution failed"
			}
		} else {
			$testResult = "FAIL"
			LogErr "Disable SRIOV is failed"
		}
		$resultArr += $testResult
		$currentTestResult.TestSummary +=  CreateResultSummary -testResult "$($syntheticResult.DpdkVersion) : TxPPS : $($syntheticResult.TxPps) : RxPPS : $($syntheticResult.RxPps)" -metaData "DPDK-TESTPMD : Synthetic" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName

        #enable SRIOV
        $currentDir = "$LogDir\finallSRIOVTest"
		New-Item -Path $currentDir -ItemType Directory | Out-Null
        $sriovStatus = Set-SRIOVInVMs -VirtualMachinesGroupName $AllVMData.ResourceGroupName[0] -Enable
		$clientVMData.PublicIP = $AllVMData.PublicIP[0]
		if ($sriovStatus -eq $true) {
			LogMsg "SRIOV is enabled"
			$finalSriovTest = Run_Dpdk_TestPmd
			if ($finalSriovTest -eq $true) {
				$finalSriovResult = Import-Csv -Path $currentDir\dpdkTestPmd.csv
				LogMsg ($finalSriovResult | Format-Table | Out-String)
				$testResult = "PASS"
			} else {
				$testResult = "FAIL"
				LogErr "Re-Enabled SRIOV DPDK test execution failed"
			}
		} else {
			$testResult = "FAIL"
			LogErr "Enable SRIOV is failed"
		}
		$resultArr += $testResult
		$currentTestResult.TestSummary +=  CreateResultSummary -testResult "$($finalSriovResult.DpdkVersion) : TxPps : $($finalSriovResult.TxPps) : RxPps : $($finalSriovResult.RxPps)" -metaData "DPDK-TESTPMD : Re-Enable SRIOV" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
		LogMsg "Comparison of DPDK RxPPS between Initial and Re-Enabled SRIOV"
		if (($null -ne $initialSriovResult.RxPps) -and ($null -ne $finalSriovResult.RxPps)) {
			$loss = [Math]::Round([Math]::Abs($initialSriovResult.RxPps - $finalSriovResult.RxPps)/$initialSriovResult.RxPps*100, 2)
			$lossinpercentage = "$loss"+" %"
			if (($loss -le 5) -or ($initialSriovResult.RxPps -ge $lowerbound -and $finalSriovResult.RxPps -ge $lowerbound)){
				$testResult = "PASS"
				LogMsg "Initial and Re-Enabled SRIOV DPDK RxPPS is greater than $lowerbound (lower bound limit) and difference is : $lossinpercentage"
			} else {
				$testResult = "FAIL"
				LogErr "Initial and Re-Enabled SRIOV DPDK RxPPS is less than $lowerbound (lower bound limit) and difference is : $lossinpercentage"
			}
		} else {
			LogErr "DPDK RxPPS of Initial or Re-Enabled SRIOV is zero."
			$testResult = "FAIL"
		}
		$resultArr += $testResult
		$currentTestResult.TestSummary +=  CreateResultSummary -testResult "$($initialSriovResult.RxPps) : $($finalSriovResult.RxPps) : $($lossinpercentage)" -metaData "DPDK RxPPS : Difference between Initial and Re-Enabled SRIOV" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
        LogMsg "Test result : $testResult"
    } catch {
        $ErrorMessage =  $_.Exception.Message
        $ErrorLine = $_.InvocationInfo.ScriptLineNumber
        LogErr "EXCEPTION : $ErrorMessage at line: $ErrorLine"
        $testResult = "FAIL"
    } finally {
        if (!$testResult) {
            $testResult = "ABORTED"
        }
        $resultArr += $testResult
    }
    $currentTestResult.TestResult = GetFinalResultHeader -resultarr $resultArr
    return $currentTestResult.TestResult
}

Main
