//
//  StatusTableViewController.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 9/6/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//

import UIKit
import HealthKit
import Intents
import LoopCore
import LoopKit
import LoopKitUI
import LoopUI
import SwiftCharts
import os.log


private extension RefreshContext {
    static let all: Set<RefreshContext> = [.status, .glucose, .insulin, .carbs, .targets]
}

final class StatusTableViewController: ChartsTableViewController {

    private let log = OSLog(category: "StatusTableViewController")

    lazy var quantityFormatter: QuantityFormatter = QuantityFormatter()

    override func viewDidLoad() {
        super.viewDidLoad()

        charts.glucoseDisplayRange = (
            min: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 100),
            max: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 175)
        )
        
        if let pumpManager = deviceManager.pumpManager {
            self.basalDeliveryState = pumpManager.status.basalDeliveryState
            pumpManager.addStatusObserver(self)
        }

        let notificationCenter = NotificationCenter.default

        notificationObservers += [
            notificationCenter.addObserver(forName: .LoopDataUpdated, object: deviceManager.loopManager, queue: nil) { [weak self] note in
                let rawContext = note.userInfo?[LoopDataManager.LoopUpdateContextKey] as! LoopDataManager.LoopUpdateContext.RawValue
                let context = LoopDataManager.LoopUpdateContext(rawValue: rawContext)
                DispatchQueue.main.async {
                    switch context {
                    case .none, .bolus?:
                        self?.refreshContext.formUnion([.status, .insulin])
                    case .preferences?:
                        self?.refreshContext.formUnion([.status, .targets])
                    case .carbs?:
                        self?.refreshContext.update(with: .carbs)
                    case .glucose?:
                        self?.refreshContext.formUnion([.glucose, .carbs])
                    case .tempBasal?:
                        self?.refreshContext.update(with: .insulin)
                    }

                    self?.hudView?.loopCompletionHUD.loopInProgress = false
                    self?.log.debug("[reloadData] from notification with context %{public}@", String(describing: context))
                    self?.reloadData(animated: true)
                }
            },
            notificationCenter.addObserver(forName: .LoopRunning, object: deviceManager.loopManager, queue: nil) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.hudView?.loopCompletionHUD.loopInProgress = true
                }
            },
            notificationCenter.addObserver(forName: .PumpManagerChanged, object: deviceManager, queue: nil) { [weak self] (notification: Notification) in
                DispatchQueue.main.async {
                    self?.configurePumpManagerHUDViews()
                }
            }

        ]

        if let gestureRecognizer = charts.gestureRecognizer {
            tableView.addGestureRecognizer(gestureRecognizer)
        }

        tableView.estimatedRowHeight = 70

        // Estimate an initial value
        landscapeMode = UIScreen.main.bounds.size.width > UIScreen.main.bounds.size.height

        // Toolbar
        toolbarItems![0].accessibilityLabel = NSLocalizedString("Add Meal", comment: "The label of the carb entry button")
        toolbarItems![0].tintColor = UIColor.COBTintColor
        toolbarItems![4].accessibilityLabel = NSLocalizedString("Bolus", comment: "The label of the bolus entry button")
        toolbarItems![4].tintColor = UIColor.doseTintColor
        toolbarItems![8].accessibilityLabel = NSLocalizedString("Settings", comment: "The label of the settings button")
        toolbarItems![8].tintColor = UIColor.secondaryLabelColor

        tableView.register(BolusProgressTableViewCell.nib(), forCellReuseIdentifier: BolusProgressTableViewCell.className)
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()

        if !visible {
            refreshContext.formUnion(RefreshContext.all)
        }
    }

    private var appearedOnce = false

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        navigationController?.setNavigationBarHidden(true, animated: animated)

        updateBolusProgress()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        if !appearedOnce {
            appearedOnce = true

            if deviceManager.loopManager.authorizationRequired {
                deviceManager.loopManager.authorize {
                    DispatchQueue.main.async {
                        self.log.debug("[reloadData] after HealthKit authorization")
                        self.reloadData()
                    }
                }
            }
        }

        onscreen = true

        AnalyticsManager.shared.didDisplayStatusScreen()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        onscreen = false

        if presentedViewController == nil {
            navigationController?.setNavigationBarHidden(false, animated: animated)
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        refreshContext.update(with: .size(size))

        super.viewWillTransition(to: size, with: coordinator)
    }

    // MARK: - State

    override var active: Bool {
        didSet {
            hudView?.loopCompletionHUD.assertTimer(active)
            updateHUDActive()
        }
    }

    // This is similar to the visible property, but is set later, on viewDidAppear, to be
    // suitable for animations that should be seen in their entirety.
    var onscreen: Bool = false {
        didSet {
            updateHUDActive()
        }
    }

    private var bolusState = PumpManagerStatus.BolusState.none {
        didSet {
            if oldValue != bolusState {
                // Bolus starting
                if case .inProgress = bolusState {
                    self.bolusProgressReporter = self.deviceManager.pumpManager?.createBolusProgressReporter(reportingOn: DispatchQueue.main)
                }
                refreshContext.update(with: .status)
                self.reloadData(animated: true)
            }
        }
    }

    private var bolusProgressReporter: DoseProgressReporter?

    private func updateBolusProgress() {
        if let cell = tableView.cellForRow(at: IndexPath(row: StatusRow.status.rawValue, section: Section.status.rawValue)) as? BolusProgressTableViewCell {
            cell.deliveredUnits = bolusProgressReporter?.progress.deliveredUnits
        }
    }

    private func updateHUDActive() {
        deviceManager.pumpManagerHUDProvider?.visible = active && onscreen
    }
    
    public var basalDeliveryState: PumpManagerStatus.BasalDeliveryState = .active {
        didSet {
            if oldValue != basalDeliveryState {
                refreshContext.update(with: .status)
            }
        }
    }

    // Toggles the display mode based on the screen aspect ratio. Should not be updated outside of reloadData().
    private var landscapeMode = false

    private var lastLoopError: Error?

    private var reloading = false

    private var refreshContext = RefreshContext.all

    private var shouldShowHUD: Bool {
        return !landscapeMode
    }

    private var shouldShowStatus: Bool {
        return !landscapeMode && statusRowMode.hasRow
    }

    override func glucoseUnitDidChange() {
        refreshContext = RefreshContext.all
    }

    private func updateChartDateRange() {
        let settings = deviceManager.loopManager.settings

        // How far back should we show data? Use the screen size as a guide.
        let availableWidth = (refreshContext.newSize ?? self.tableView.bounds.size).width - self.charts.fixedHorizontalMargin

        let totalHours = floor(Double(availableWidth / settings.minimumChartWidthPerHour))
        let futureHours = ceil((deviceManager.loopManager.insulinModelSettings?.model.effectDuration ?? .hours(4)).hours)
        let historyHours = max(settings.statusChartMinimumHistoryDisplay.hours, totalHours - futureHours)

        let date = Date(timeIntervalSinceNow: -TimeInterval(hours: historyHours))
        let chartStartDate = Calendar.current.nextDate(after: date, matching: DateComponents(minute: 0), matchingPolicy: .strict, direction: .backward) ?? date
        if charts.startDate != chartStartDate {
            refreshContext.formUnion(RefreshContext.all)
        }
        charts.startDate = chartStartDate
        charts.maxEndDate = chartStartDate.addingTimeInterval(.hours(totalHours))
        charts.updateEndDate(charts.maxEndDate)
    }

    override func reloadData(animated: Bool = false) {
        // This should be kept up to date immediately
        hudView?.loopCompletionHUD.lastLoopCompleted = deviceManager.loopManager.lastLoopCompleted

        guard !reloading && !deviceManager.loopManager.authorizationRequired else {
            return
        }

        updateChartDateRange()
        redrawCharts()

        if case .bolusing = statusRowMode, bolusProgressReporter?.progress.isComplete == true {
            refreshContext.update(with: .status)
        }

        if visible && active {
            bolusProgressReporter?.addObserver(self)
        } else {
            bolusProgressReporter?.removeObserver(self)
        }

        guard active && visible && !refreshContext.isEmpty else {
            return
        }

        log.debug("Reloading data with context: %@", String(describing: refreshContext))

        let currentContext = refreshContext
        var retryContext: Set<RefreshContext> = []
        self.refreshContext = []
        reloading = true

        let reloadGroup = DispatchGroup()
        var newRecommendedTempBasal: (recommendation: TempBasalRecommendation, date: Date)?
        var glucoseValues: [StoredGlucoseSample]?
        var predictedGlucoseValues: [GlucoseValue]?
        var iobValues: [InsulinValue]?
        var doseEntries: [DoseEntry]?
        var totalDelivery: Double?
        var cobValues: [CarbValue]?
        let startDate = charts.startDate

        // TODO: Don't always assume currentContext.contains(.status)
        reloadGroup.enter()
        self.deviceManager.loopManager.getLoopState { (manager, state) -> Void in
            predictedGlucoseValues = state.predictedGlucose ?? []

            // Retry this refresh again if predicted glucose isn't available
            if state.predictedGlucose == nil {
                retryContext.update(with: .status)
            }

            /// Update the status HUDs immediately
            let netBasal: NetBasal?
            let lastLoopCompleted = manager.lastLoopCompleted
            let lastLoopError = state.error

            // Net basal rate HUD
            let date = state.lastTempBasal?.startDate ?? Date()
            if let scheduledBasal = manager.basalRateSchedule?.between(start: date, end: date).first {
                netBasal = NetBasal(
                    lastTempBasal: state.lastTempBasal,
                    maxBasal: manager.settings.maximumBasalRatePerHour,
                    scheduledBasal: scheduledBasal
                )
            } else {
                netBasal = nil
            }

            DispatchQueue.main.async {
                self.hudView?.loopCompletionHUD.dosingEnabled = manager.settings.dosingEnabled
                self.lastLoopError = lastLoopError

                if let netBasal = netBasal {
                    self.hudView?.basalRateHUD.setNetBasalRate(netBasal.rate, percent: netBasal.percent, at: netBasal.start)
                }
            }

            // Display a recommended basal change only if we haven't completed recently, or we're in open-loop mode
            if lastLoopCompleted == nil ||
                lastLoopCompleted! < Date(timeIntervalSinceNow: .minutes(-6)) ||
                !manager.settings.dosingEnabled
            {
                newRecommendedTempBasal = state.recommendedTempBasal
            }

            if currentContext.contains(.carbs) {
                reloadGroup.enter()
                manager.carbStore.getCarbsOnBoardValues(start: startDate, effectVelocities: manager.settings.dynamicCarbAbsorptionEnabled ? state.insulinCounteractionEffects : nil) { (values) in
                    cobValues = values
                    reloadGroup.leave()
                }
            }

            reloadGroup.leave()
        }

        if currentContext.contains(.glucose) {
            reloadGroup.enter()
            self.deviceManager.loopManager.glucoseStore.getCachedGlucoseSamples(start: startDate) { (values) -> Void in
                glucoseValues = values
                reloadGroup.leave()
            }
        }

        if currentContext.contains(.insulin) {
            reloadGroup.enter()
            deviceManager.loopManager.doseStore.getInsulinOnBoardValues(start: startDate) { (result) -> Void in
                switch result {
                case .failure(let error):
                    self.deviceManager.logger.addError(error, fromSource: "DoseStore")
                    retryContext.update(with: .insulin)
                    iobValues = []
                case .success(let values):
                    iobValues = values
                }
                reloadGroup.leave()
            }

            reloadGroup.enter()
            deviceManager.loopManager.doseStore.getNormalizedDoseEntries(start: startDate) { (result) -> Void in
                switch result {
                case .failure(let error):
                    self.deviceManager.logger.addError(error, fromSource: "DoseStore")
                    retryContext.update(with: .insulin)
                    doseEntries = []
                case .success(let doses):
                    doseEntries = doses
                }
                reloadGroup.leave()
            }

            reloadGroup.enter()
            deviceManager.loopManager.doseStore.getTotalUnitsDelivered(since: Calendar.current.startOfDay(for: Date())) { (result) in
                switch result {
                case .failure:
                    retryContext.update(with: .insulin)
                    totalDelivery = nil
                case .success(let total):
                    totalDelivery = total.value
                }

                reloadGroup.leave()
            }
        }

        workoutMode = deviceManager.loopManager.settings.glucoseTargetRangeSchedule?.overrideEnabledForContext(.workout)
        preMealMode = deviceManager.loopManager.settings.glucoseTargetRangeSchedule?.overrideEnabledForContext(.preMeal)

        reloadGroup.notify(queue: .main) {
            /// Update the chart data

            // Glucose
            if let glucoseValues = glucoseValues {
                self.charts.setGlucoseValues(glucoseValues)
            }
            if let predictedGlucoseValues = predictedGlucoseValues {
                self.charts.setPredictedGlucoseValues(predictedGlucoseValues)
            }
            if let lastPoint = self.charts.predictedGlucosePoints.last?.y {
                self.eventualGlucoseDescription = String(describing: lastPoint)
            } else {
                self.eventualGlucoseDescription = nil
            }
            if currentContext.contains(.targets) {
                self.charts.targetGlucoseSchedule = self.deviceManager.loopManager.settings.glucoseTargetRangeSchedule
            }

            // Active Insulin
            if let iobValues = iobValues {
                self.charts.setIOBValues(iobValues)
            }
            if let index = self.charts.iobPoints.closestIndexPriorToDate(Date()) {
                self.currentIOBDescription = String(describing: self.charts.iobPoints[index].y)
            } else {
                self.currentIOBDescription = nil
            }

            // Insulin Delivery
            if let doseEntries = doseEntries {
                self.charts.setDoseEntries(doseEntries)
            }
            if let totalDelivery = totalDelivery {
                self.totalDelivery = totalDelivery
            }

            // Active Carbohydrates
            if let cobValues = cobValues {
                self.charts.setCOBValues(cobValues)
            }
            if let index = self.charts.cobPoints.closestIndexPriorToDate(Date()) {
                self.currentCOBDescription = String(describing: self.charts.cobPoints[index].y)
            } else {
                self.currentCOBDescription = nil
            }

            self.tableView.beginUpdates()
            if let hudView = self.hudView {
                // Glucose HUD
                if let glucose = self.deviceManager.loopManager.glucoseStore.latestGlucose {
                    hudView.glucoseHUD.setGlucoseQuantity(glucose.quantity.doubleValue(for: self.charts.glucoseUnit),
                        at: glucose.startDate,
                        unit: self.charts.glucoseUnit,
                        sensor: self.deviceManager.cgmManager?.sensorState
                    )
                }
            }

            // Show/hide the table view rows
            let statusRowMode = self.determineStatusRowMode(recommendedTempBasal: newRecommendedTempBasal)

            self.updateHUDandStatusRows(statusRowMode: statusRowMode, newSize: currentContext.newSize, animated: animated)

            self.redrawCharts()

            self.tableView.endUpdates()

            self.reloading = false
            let reloadNow = !self.refreshContext.isEmpty
            self.refreshContext.formUnion(retryContext)

            // Trigger a reload if new context exists.
            if reloadNow {
                self.log.debug("[reloadData] due to context change during previous reload")
                self.reloadData()
            }
        }
    }

    private enum Section: Int {
        case hud = 0
        case status
        case charts

        static let count = 3
    }

    // MARK: - Chart Section Data

    private enum ChartRow: Int {
        case glucose = 0
        case iob
        case dose
        case cob

        static let count = 4
    }

    // MARK: Glucose

    private var eventualGlucoseDescription: String?

    // MARK: IOB

    private var currentIOBDescription: String?

    // MARK: Dose

    private var totalDelivery: Double?

    // MARK: COB

    private var currentCOBDescription: String?

    // MARK: - Loop Status Section Data

    private enum StatusRow: Int {
        case status = 0

        static let count = 1
    }

    private enum StatusRowMode {
        case hidden
        case recommendedTempBasal(tempBasal: TempBasalRecommendation, at: Date, enacting: Bool)
        case enactingBolus
        case bolusing(dose: DoseEntry)
        case cancelingBolus
        case pumpSuspended(resuming: Bool)

        var hasRow: Bool {
            switch self {
            case .hidden:
                return false
            default:
                return true
            }
        }
    }

    private var statusRowMode = StatusRowMode.hidden

    private func determineStatusRowMode(recommendedTempBasal: (recommendation: TempBasalRecommendation, date: Date)? = nil) -> StatusRowMode {
        let statusRowMode: StatusRowMode

        if case .initiating = bolusState {
            statusRowMode = .enactingBolus
        } else if case .canceling = bolusState {
            statusRowMode = .cancelingBolus
        } else if self.basalDeliveryState == .suspended {
            statusRowMode = .pumpSuspended(resuming: false)
        } else if self.basalDeliveryState == .resuming {
            statusRowMode = .pumpSuspended(resuming: true)
        } else {
            if case .inProgress(let dose) = bolusState, dose.endDate.timeIntervalSinceNow > 0 {
                statusRowMode = .bolusing(dose: dose)
            } else if let (recommendation: tempBasal, date: date) = recommendedTempBasal {
                statusRowMode = .recommendedTempBasal(tempBasal: tempBasal, at: date, enacting: false)
            } else {
                statusRowMode = .hidden
            }
        }

        return statusRowMode
    }

    private func updateHUDandStatusRows(statusRowMode: StatusRowMode, newSize: CGSize?, animated: Bool) {
        let hudWasVisible = self.shouldShowHUD
        let statusWasVisible = self.shouldShowStatus

        let oldStatusRowMode = self.statusRowMode

        self.statusRowMode = statusRowMode

        if let newSize = newSize {
            self.landscapeMode = newSize.width > newSize.height
        }

        let hudIsVisible = self.shouldShowHUD
        let statusIsVisible = self.shouldShowStatus

        tableView.beginUpdates()

        switch (hudWasVisible, hudIsVisible) {
        case (false, true):
            self.tableView.insertRows(at: [IndexPath(row: 0, section: Section.hud.rawValue)], with: animated ? .top : .none)
        case (true, false):
            self.tableView.deleteRows(at: [IndexPath(row: 0, section: Section.hud.rawValue)], with: animated ? .top : .none)
        default:
            break
        }

        let statusIndexPath = IndexPath(row: StatusRow.status.rawValue, section: Section.status.rawValue)

        switch (statusWasVisible, statusIsVisible) {
        case (true, true):
            switch (oldStatusRowMode, self.statusRowMode) {
            case (.recommendedTempBasal(tempBasal: let oldTempBasal, at: let oldDate, enacting: let wasEnacting),
                  .recommendedTempBasal(tempBasal: let newTempBasal, at: let newDate, enacting: let isEnacting)):
                // Ensure we have a change
                guard oldTempBasal != newTempBasal || oldDate != newDate || wasEnacting != isEnacting else {
                    break
                }

                // If the rate or date change, reload the row
                if oldTempBasal != newTempBasal || oldDate != newDate {
                    self.tableView.reloadRows(at: [statusIndexPath], with: animated ? .fade : .none)
                } else if let cell = tableView.cellForRow(at: statusIndexPath) {
                    // If only the enacting state changed, update the activity indicator
                    if isEnacting {
                        let indicatorView = UIActivityIndicatorView(activityIndicatorStyle: .gray)
                        indicatorView.startAnimating()
                        cell.accessoryView = indicatorView
                    } else {
                        cell.accessoryView = nil
                    }
                }
            case (.enactingBolus, .enactingBolus):
                break
            case (.bolusing(let oldDose), .bolusing(let newDose)):
                if oldDose != newDose {
                    self.tableView.reloadRows(at: [statusIndexPath], with: animated ? .fade : .none)
                }
            case (.pumpSuspended(resuming: let wasResuming), .pumpSuspended(resuming: let isResuming)):
                if isResuming != wasResuming {
                    self.tableView.reloadRows(at: [statusIndexPath], with: animated ? .fade : .none)
                }
            default:
                self.tableView.reloadRows(at: [statusIndexPath], with: animated ? .fade : .none)
            }
        case (false, true):
            self.tableView.insertRows(at: [statusIndexPath], with: animated ? .top : .none)
        case (true, false):
            self.tableView.deleteRows(at: [statusIndexPath], with: animated ? .top : .none)
        default:
            break
        }

        tableView.endUpdates()
    }

    private func redrawCharts() {
        tableView.beginUpdates()
        self.charts.prerender()
        for case let cell as ChartTableViewCell in self.tableView.visibleCells {
            cell.reloadChart()

            if let indexPath = self.tableView.indexPath(for: cell) {
                self.tableView(self.tableView, updateSubtitleFor: cell, at: indexPath)
            }
        }
        tableView.endUpdates()
    }

    // MARK: - Toolbar data

    private var preMealMode: Bool? = nil {
        didSet {
            guard oldValue != preMealMode else {
                return
            }

            if let preMealMode = preMealMode {
                toolbarItems![2] = createPreMealButtonItem(selected: preMealMode)
            } else {
                toolbarItems![2].isEnabled = false
            }
        }
    }

    private var workoutMode: Bool? = nil {
        didSet {
            guard oldValue != workoutMode else {
                return
            }

            if let workoutMode = workoutMode {
                toolbarItems![6] = createWorkoutButtonItem(selected: workoutMode)
            } else {
                toolbarItems![6].isEnabled = false
            }
        }
    }

    // MARK: - Table view data source

    override func numberOfSections(in tableView: UITableView) -> Int {
        return Section.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .hud:
            return shouldShowHUD ? 1 : 0
        case .charts:
            return ChartRow.count
        case .status:
            return shouldShowStatus ? StatusRow.count : 0
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .hud:
            let cell = tableView.dequeueReusableCell(withIdentifier: HUDViewTableViewCell.className, for: indexPath) as! HUDViewTableViewCell
            self.hudView = cell.hudView

            return cell
        case .charts:
            let cell = tableView.dequeueReusableCell(withIdentifier: ChartTableViewCell.className, for: indexPath) as! ChartTableViewCell

            switch ChartRow(rawValue: indexPath.row)! {
            case .glucose:
                cell.chartContentView.chartGenerator = { [weak self] (frame) in
                    return self?.charts.glucoseChartWithFrame(frame)?.view
                }
                cell.titleLabel?.text = NSLocalizedString("Glucose", comment: "The title of the glucose and prediction graph")
            case .iob:
                cell.chartContentView.chartGenerator = { [weak self] (frame) in
                    return self?.charts.iobChartWithFrame(frame)?.view
                }
                cell.titleLabel?.text = NSLocalizedString("Active Insulin", comment: "The title of the Insulin On-Board graph")
            case .dose:
                cell.chartContentView?.chartGenerator = { [weak self] (frame) in
                    return self?.charts.doseChartWithFrame(frame)?.view
                }
                cell.titleLabel?.text = NSLocalizedString("Insulin Delivery", comment: "The title of the insulin delivery graph")
            case .cob:
                cell.chartContentView?.chartGenerator = { [weak self] (frame) in
                    return self?.charts.cobChartWithFrame(frame)?.view
                }
                cell.titleLabel?.text = NSLocalizedString("Active Carbohydrates", comment: "The title of the Carbs On-Board graph")
            }

            self.tableView(tableView, updateSubtitleFor: cell, at: indexPath)

            let alpha: CGFloat = charts.gestureRecognizer?.state == .possible ? 1 : 0
            cell.titleLabel?.alpha = alpha
            cell.subtitleLabel?.alpha = alpha

            cell.subtitleLabel?.textColor = UIColor.secondaryLabelColor

            return cell
        case .status:

            func getTitleSubtitleCell() -> TitleSubtitleTableViewCell {
                let cell = tableView.dequeueReusableCell(withIdentifier: TitleSubtitleTableViewCell.className, for: indexPath) as! TitleSubtitleTableViewCell
                cell.selectionStyle = .none
                return cell
            }

            switch StatusRow(rawValue: indexPath.row)! {
            case .status:
                switch statusRowMode {
                case .hidden:
                    let cell = getTitleSubtitleCell()
                    cell.titleLabel.text = nil
                    cell.subtitleLabel?.text = nil
                    cell.accessoryView = nil
                    return cell
                case .recommendedTempBasal(tempBasal: let tempBasal, at: let date, enacting: let enacting):
                    let cell = getTitleSubtitleCell()
                    let timeFormatter = DateFormatter()
                    timeFormatter.dateStyle = .none
                    timeFormatter.timeStyle = .short

                    cell.titleLabel.text = NSLocalizedString("Recommended Basal", comment: "The title of the cell displaying a recommended temp basal value")
                    cell.subtitleLabel?.text = String(format: NSLocalizedString("%1$@ U/hour @ %2$@", comment: "The format for recommended temp basal rate and time. (1: localized rate number)(2: localized time)"), NumberFormatter.localizedString(from: NSNumber(value: tempBasal.unitsPerHour), number: .decimal), timeFormatter.string(from: date))
                    cell.selectionStyle = .default

                    if enacting {
                        let indicatorView = UIActivityIndicatorView(activityIndicatorStyle: .gray)
                        indicatorView.startAnimating()
                        cell.accessoryView = indicatorView
                    } else {
                        cell.accessoryView = nil
                    }
                    return cell
                case .enactingBolus:
                    let cell = getTitleSubtitleCell()
                    cell.titleLabel.text = NSLocalizedString("Starting Bolus", comment: "The title of the cell indicating a bolus is being sent")
                    cell.subtitleLabel.text = nil

                    let indicatorView = UIActivityIndicatorView(activityIndicatorStyle: .gray)
                    indicatorView.startAnimating()
                    cell.accessoryView = indicatorView
                    return cell
                case .bolusing(let dose):
                    let progressCell = tableView.dequeueReusableCell(withIdentifier: BolusProgressTableViewCell.className, for: indexPath) as! BolusProgressTableViewCell
                    progressCell.selectionStyle = .none
                    progressCell.totalUnits = dose.units
                    progressCell.tintColor = .doseTintColor
                    progressCell.unit = HKUnit.internationalUnit()
                    progressCell.deliveredUnits = bolusProgressReporter?.progress.deliveredUnits
                    return progressCell
                case .cancelingBolus:
                    let cell = getTitleSubtitleCell()
                    cell.titleLabel.text = NSLocalizedString("Canceling Bolus", comment: "The title of the cell indicating a bolus is being canceled")
                    cell.subtitleLabel.text = nil

                    let indicatorView = UIActivityIndicatorView(activityIndicatorStyle: .gray)
                    indicatorView.startAnimating()
                    cell.accessoryView = indicatorView
                    return cell
                case .pumpSuspended(let resuming):
                    let cell = getTitleSubtitleCell()
                    cell.titleLabel.text = NSLocalizedString("Pump Suspended", comment: "The title of the cell indicating the pump is suspended")

                    if resuming {
                        let indicatorView = UIActivityIndicatorView(activityIndicatorStyle: .gray)
                        indicatorView.startAnimating()
                        cell.accessoryView = indicatorView
                        cell.subtitleLabel.text = ""
                    } else {
                        cell.subtitleLabel.text = NSLocalizedString("Tap to Resume", comment: "The subtitle of the cell displaying an action to resume insulin delivery")
                    }
                    cell.selectionStyle = .default
                    return cell
                }
            }
        }
    }

    private func tableView(_ tableView: UITableView, updateSubtitleFor cell: ChartTableViewCell, at indexPath: IndexPath) {
        switch Section(rawValue: indexPath.section)! {
        case .charts:
            switch ChartRow(rawValue: indexPath.row)! {
            case .glucose:
                if let eventualGlucose = eventualGlucoseDescription {
                    cell.subtitleLabel?.text = String(format: NSLocalizedString("Eventually %@", comment: "The subtitle format describing eventual glucose. (1: localized glucose value description)"), eventualGlucose)
                } else {
                    cell.subtitleLabel?.text = nil
                }
            case .iob:
                if let currentIOB = currentIOBDescription {
                    cell.subtitleLabel?.text = currentIOB
                } else {
                    cell.subtitleLabel?.text = nil
                }
            case .dose:
                let integerFormatter = NumberFormatter()
                integerFormatter.maximumFractionDigits = 0

                if  let total = totalDelivery,
                    let totalString = integerFormatter.string(from: total) {
                    cell.subtitleLabel?.text = String(format: NSLocalizedString("%@ U Total", comment: "The subtitle format describing total insulin. (1: localized insulin total)"), totalString)
                } else {
                    cell.subtitleLabel?.text = nil
                }
            case .cob:
                if let currentCOB = currentCOBDescription {
                    cell.subtitleLabel?.text = currentCOB
                } else {
                    cell.subtitleLabel?.text = nil
                }
            }
        case .hud, .status:
            break
        }
    }

    // MARK: - UITableViewDelegate

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        switch Section(rawValue: indexPath.section)! {
        case .charts:
            // Compute the height of the HUD, defaulting to 70
            let hudHeight = ceil(hudView?.systemLayoutSizeFitting(UILayoutFittingCompressedSize).height ?? 70)
            var availableSize = max(tableView.bounds.width, tableView.bounds.height)

            if #available(iOS 11.0, *) {
                availableSize -= (tableView.safeAreaInsets.top + tableView.safeAreaInsets.bottom + hudHeight)
            } else {
                // 20: Status bar
                // 44: Toolbar
                availableSize -= hudHeight + 20 + 44
            }

            switch ChartRow(rawValue: indexPath.row)! {
            case .glucose:
                return max(106, 0.37 * availableSize)
            case .iob, .dose, .cob:
                return max(106, 0.21 * availableSize)
            }
        case .hud, .status:
            return UITableViewAutomaticDimension
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        switch Section(rawValue: indexPath.section)! {
        case .charts:
            switch ChartRow(rawValue: indexPath.row)! {
            case .glucose:
                performSegue(withIdentifier: PredictionTableViewController.className, sender: indexPath)
            case .iob, .dose:
                performSegue(withIdentifier: InsulinDeliveryTableViewController.className, sender: indexPath)
            case .cob:
                performSegue(withIdentifier: CarbAbsorptionViewController.className, sender: indexPath)
            }
        case .status:
            switch StatusRow(rawValue: indexPath.row)! {
            case .status:
                tableView.deselectRow(at: indexPath, animated: true)

                switch statusRowMode {
                case .recommendedTempBasal(tempBasal: let tempBasal, at: let date, enacting: let enacting) where !enacting:
                    self.updateHUDandStatusRows(statusRowMode: .recommendedTempBasal(tempBasal: tempBasal, at: date, enacting: true), newSize: nil, animated: true)

                    self.deviceManager.loopManager.enactRecommendedTempBasal { (error) in
                        DispatchQueue.main.async {
                            self.updateHUDandStatusRows(statusRowMode: .hidden, newSize: nil, animated: true)

                            if let error = error {
                                self.deviceManager.logger.addError(error, fromSource: "TempBasal")
                                self.present(UIAlertController(with: error), animated: true)
                            } else {
                                self.refreshContext.update(with: .status)
                                self.log.debug("[reloadData] after manually enacting temp basal")
                                self.reloadData()
                            }
                        }
                    }
                case .pumpSuspended(let resuming) where !resuming:
                    self.updateHUDandStatusRows(statusRowMode: .pumpSuspended(resuming: true) , newSize: nil, animated: true)
                    self.deviceManager.pumpManager?.resumeDelivery() { (error) in
                        DispatchQueue.main.async {
                            if let error = error {
                                let alert = UIAlertController(with: error, title: NSLocalizedString("Error Resuming", comment: "The alert title for a resume error"))
                                self.present(alert, animated: true, completion: nil)
                                if case .suspended = self.basalDeliveryState {
                                    self.updateHUDandStatusRows(statusRowMode: .pumpSuspended(resuming: false), newSize: nil, animated: true)
                                }
                            } else {
                                self.updateHUDandStatusRows(statusRowMode: .hidden, newSize: nil, animated: true)
                            }
                        }
                    }
                case .bolusing:
                    self.updateHUDandStatusRows(statusRowMode: .cancelingBolus, newSize: nil, animated: true)
                    self.deviceManager.pumpManager?.cancelBolus() { (result) in
                        DispatchQueue.main.async {
                            switch result {
                            case .success:
                                // show user confirmation and actual delivery amount?
                                break
                            case .failure(let error):
                                let alert = UIAlertController(with: error, title: NSLocalizedString("Error Canceling Bolus", comment: "The alert title for an error while canceling a bolus"))
                                self.present(alert, animated: true, completion: nil)
                                if case .inProgress(let dose) = self.bolusState {
                                    self.updateHUDandStatusRows(statusRowMode: .bolusing(dose: dose), newSize: nil, animated: true)
                                } else {
                                    self.updateHUDandStatusRows(statusRowMode: .hidden, newSize: nil, animated: true)
                                }
                            }
                        }
                    }

                default:
                    break
                }
            }
        case .hud:
            break
        }
    }

    // MARK: - Actions

    override func restoreUserActivityState(_ activity: NSUserActivity) {
        switch activity.activityType {
        case NSUserActivity.newCarbEntryActivityType:
            performSegue(withIdentifier: CarbEntryEditViewController.className, sender: activity)
        default:
            break
        }
    }

    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        super.prepare(for: segue, sender: sender)

        var targetViewController = segue.destination

        if let navVC = targetViewController as? UINavigationController, let topViewController = navVC.topViewController {
            targetViewController = topViewController
        }

        switch targetViewController {
        case let vc as CarbAbsorptionViewController:
            vc.deviceManager = deviceManager
            vc.hidesBottomBarWhenPushed = true
        case let vc as CarbEntryTableViewController:
            vc.carbStore = deviceManager.loopManager.carbStore
            vc.hidesBottomBarWhenPushed = true
        case let vc as CarbEntryEditViewController:
            vc.defaultAbsorptionTimes = deviceManager.loopManager.carbStore.defaultAbsorptionTimes
            vc.preferredUnit = deviceManager.loopManager.carbStore.preferredUnit

            if let activity = sender as? NSUserActivity {
                vc.restoreUserActivityState(activity)
            }
        case let vc as InsulinDeliveryTableViewController:
            vc.doseStore = deviceManager.loopManager.doseStore
            vc.hidesBottomBarWhenPushed = true
        case let vc as BolusViewController:
            vc.configureWithLoopManager(self.deviceManager.loopManager,
                recommendation: sender as? BolusRecommendation,
                glucoseUnit: self.charts.glucoseUnit
            )
        case let vc as PredictionTableViewController:
            vc.deviceManager = deviceManager
        case let vc as SettingsTableViewController:
            vc.dataManager = deviceManager
        default:
            break
        }
    }

    /// Unwind segue action from the CarbEntryEditViewController
    ///
    /// - parameter segue: The unwind segue
    @IBAction func unwindFromEditing(_ segue: UIStoryboardSegue) {
        guard let carbVC = segue.source as? CarbEntryEditViewController, let updatedEntry = carbVC.updatedCarbEntry else {
            return
        }

        if #available(iOS 12.0, *) {
            let interaction = INInteraction(intent: NewCarbEntryIntent(), response: nil)
            interaction.donate { [weak self] (error) in
                if let error = error {
                    self?.log.error("Failed to donate intent: %{public}@", String(describing: error))
                }
            }
        }
        deviceManager.loopManager.addCarbEntryAndRecommendBolus(updatedEntry) { (result) -> Void in
            DispatchQueue.main.async {
                switch result {
                case .success(let recommendation):
                    if self.active && self.visible, let bolus = recommendation?.amount, bolus > 0 {
                        self.performSegue(withIdentifier: BolusViewController.className, sender: recommendation)
                    }
                case .failure(let error):
                    // Ignore bolus wizard errors
                    if error is CarbStore.CarbStoreError {
                        self.present(UIAlertController(with: error), animated: true)
                    } else {
                        self.deviceManager.logger.addError(error, fromSource: "Bolus")
                    }
                }
            }
        }
    }

    @IBAction func unwindFromBolusViewController(_ segue: UIStoryboardSegue) {
        if let bolusViewController = segue.source as? BolusViewController {
            if let bolus = bolusViewController.bolus, bolus > 0 {
                deviceManager.enactBolus(units: bolus) { (_) in }
            }
        }
    }

    @IBAction func unwindFromSettings(_ segue: UIStoryboardSegue) {
    }

    private func createPreMealButtonItem(selected: Bool) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage.preMealImage(selected: selected), style: .plain, target: self, action: #selector(togglePreMealMode(_:)))
        item.accessibilityLabel = NSLocalizedString("Pre-Meal Targets", comment: "The label of the pre-meal mode toggle button")

        if selected {
            item.accessibilityTraits = item.accessibilityTraits | UIAccessibilityTraitSelected
            item.accessibilityHint = NSLocalizedString("Disables", comment: "The action hint of the workout mode toggle button when enabled")
        } else {
            item.accessibilityHint = NSLocalizedString("Enables", comment: "The action hint of the workout mode toggle button when disabled")
        }

        item.tintColor = UIColor.COBTintColor

        return item
    }

    private func createWorkoutButtonItem(selected: Bool) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage.workoutImage(selected: selected), style: .plain, target: self, action: #selector(toggleWorkoutMode(_:)))
        item.accessibilityLabel = NSLocalizedString("Workout Targets", comment: "The label of the workout mode toggle button")

        if selected {
            item.accessibilityTraits = item.accessibilityTraits | UIAccessibilityTraitSelected
            item.accessibilityHint = NSLocalizedString("Disables", comment: "The action hint of the workout mode toggle button when enabled")
        } else {
            item.accessibilityHint = NSLocalizedString("Enables", comment: "The action hint of the workout mode toggle button when disabled")
        }

        item.tintColor = UIColor.glucoseTintColor

        return item
    }

    @IBAction func togglePreMealMode(_ sender: UIBarButtonItem) {
        if preMealMode == true {
            deviceManager.loopManager.settings.glucoseTargetRangeSchedule?.clearOverride(matching: .preMeal)
        } else {
            _ = self.deviceManager.loopManager.settings.glucoseTargetRangeSchedule?.setOverride(.preMeal, until: Date(timeIntervalSinceNow: .hours(1)))
        }
    }

    @IBAction func toggleWorkoutMode(_ sender: UIBarButtonItem) {
        if workoutMode == true {
            deviceManager.loopManager.settings.glucoseTargetRangeSchedule?.clearOverride(matching: .workout)
        } else {
            let vc = UIAlertController(workoutDurationSelectionHandler: { (endDate) in
                _ = self.deviceManager.loopManager.settings.glucoseTargetRangeSchedule?.setOverride(.workout, until: endDate)
            })

            present(vc, animated: true, completion: nil)
        }
    }

    // MARK: - HUDs

    @IBOutlet var hudView: HUDView? {
        didSet {
            guard let hudView = hudView, hudView != oldValue else {
                return
            }

            let statusTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(showLastError(_:)))
            hudView.loopCompletionHUD.addGestureRecognizer(statusTapGestureRecognizer)
            hudView.loopCompletionHUD.accessibilityHint = NSLocalizedString("Shows last loop error", comment: "Loop Completion HUD accessibility hint")

            let glucoseTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(openCGMApp(_:)))
            hudView.glucoseHUD.addGestureRecognizer(glucoseTapGestureRecognizer)
            
            if deviceManager.cgmManager?.appURL != nil {
                hudView.glucoseHUD.accessibilityHint = NSLocalizedString("Launches CGM app", comment: "Glucose HUD accessibility hint")
            }
            
            configurePumpManagerHUDViews()
            
            hudView.loopCompletionHUD.stateColors = .loopStatus
            hudView.glucoseHUD.stateColors = .cgmStatus
            hudView.glucoseHUD.tintColor = .glucoseTintColor
            hudView.basalRateHUD.tintColor = .doseTintColor

            refreshContext.update(with: .status)
            self.log.debug("[reloadData] after hudView loaded")
            reloadData()
        }
    }
    
    private func configurePumpManagerHUDViews() {
        if let hudView = hudView {
            hudView.removePumpManagerProvidedViews()
            if var pumpManagerHUDProvider = deviceManager.pumpManagerHUDProvider
            {
                let views = pumpManagerHUDProvider.createHUDViews()
                for view in views {
                    addViewToHUD(view)
                }
                pumpManagerHUDProvider.visible = active && onscreen
            } else {
                let reservoirView = ReservoirVolumeHUDView.instantiate()
                let batteryView = BatteryLevelHUDView.instantiate()
                for view in [reservoirView, batteryView] {
                    addViewToHUD(view)
                }
            }
        }
    }
    
    private func addViewToHUD(_ view: BaseHUDView) {
        if let hudView = hudView {
            let hudTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(hudViewTapped(_:)))
            view.addGestureRecognizer(hudTapGestureRecognizer)
            view.stateColors = .pumpStatus
            hudView.addHUDView(view)
        }
    }

    @objc private func showLastError(_: Any) {
        // First, check whether we have a device error after the most recent completion date
        if let deviceError = deviceManager.lastError,
            deviceError.date > (hudView?.loopCompletionHUD.lastLoopCompleted ?? .distantPast)
        {
            self.present(UIAlertController(with: deviceError.error), animated: true)
        } else if let lastLoopError = lastLoopError {
            self.present(UIAlertController(with: lastLoopError), animated: true)
        }
    }

    @objc private func openCGMApp(_: Any) {
        if let url = deviceManager.cgmManager?.appURL, UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }

    @objc private func hudViewTapped(_ sender: UIGestureRecognizer) {
        if let hudSubView = sender.view as? BaseHUDView,
            let pumpManagerHUDProvider = deviceManager.pumpManagerHUDProvider,
            let action = pumpManagerHUDProvider.didTapOnHUDView(hudSubView)
        {
            switch action {
            case .presentViewController(let vc):
                var completionNotifyingVC = vc
                completionNotifyingVC.completionDelegate = self
                self.present(vc, animated: true, completion: nil)
            case .openAppURL(let url):
                UIApplication.shared.open(url)
            }
        }
    }
}

extension StatusTableViewController: CompletionDelegate {
    func completionNotifyingDidComplete(_ object: CompletionNotifying) {
        if let vc = object as? UIViewController {
            vc.dismiss(animated: true, completion: nil)
        }
    }
}

extension StatusTableViewController: PumpManagerStatusObserver {
    func pumpManager(_ pumpManager: PumpManager, didUpdate status: PumpManagerStatus) {
        DispatchQueue.main.async {
            self.basalDeliveryState = status.basalDeliveryState
            self.bolusState = status.bolusState
        }
    }
}

extension StatusTableViewController: DoseProgressObserver {
    func doseProgressReporterDidUpdate(_ doseProgressReporter: DoseProgressReporter) {

        updateBolusProgress()

        if doseProgressReporter.progress.isComplete {
            // Bolus ended
            self.bolusProgressReporter = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: {
                self.bolusState = .none
                self.reloadData(animated: true)
            })
        }
    }
}

